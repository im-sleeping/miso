pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

// ---------------------------------------------------------------------
// SPDX-License-Identifier: GPL-3.0
// ---------------------------------------------------------------------

import '../OpenZeppelin/utils/ReentrancyGuard.sol';
import '../Access/MISOAccessControls.sol';
import '../Utils/SafeTransfer.sol';
import '../Utils/BoringBatchable.sol';
import '../Utils/BoringERC20.sol';
import '../Utils/BoringMath.sol';
import '../Utils/Documents.sol';
import '../interfaces/IPointList.sol';
import '../interfaces/IMisoMarket.sol';

/**
 * Pro‑rata fixed price auction.
 * - Fixed total tokens (T) and fixed price per token (rate)
 * - Everyone can commit during the time window
 * - If total commitments C <= T*rate, all commitments are accepted
 * - If C > T*rate, each address is accepted pro‑rata: accepted_i = commit_i * (T*rate) / C
 * - On finalize, transfer acceptedTotal to wallet; unsold tokens (if any) back to wallet
 * - Users withdraw: receive tokens (based on accepted_i) and refund the unaccepted portion
 */
contract ProRataFixedPrice is
  IMisoMarket,
  MISOAccessControls,
  BoringBatchable,
  SafeTransfer,
  Documents,
  ReentrancyGuard
{
  using BoringMath for uint256;
  using BoringMath128 for uint128;
  using BoringMath64 for uint64;
  using BoringERC20 for IERC20;

  uint256 public constant override marketTemplate = 5; // new template id

  address private constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

  uint256 private constant AUCTION_TOKEN_DECIMAL_PLACES = 18;
  uint256 private constant AUCTION_TOKEN_DECIMALS = 10 ** AUCTION_TOKEN_DECIMAL_PLACES;

  struct MarketPrice {
    uint128 rate; // payment currency units per 1 token (18 decimals on token)
    uint128 goal; // minimumCommitmentAmount in payment currency units
  }
  MarketPrice public marketPrice;

  struct MarketInfo {
    uint64 startTime;
    uint64 endTime;
    uint128 totalTokens; // tokens for sale (18 decimals)
  }
  MarketInfo public marketInfo;

  struct MarketStatus {
    uint128 commitmentsTotal; // total payment committed
    bool finalized;
    bool usePointList;
  }
  MarketStatus public marketStatus;

  address public auctionToken; // token being sold (must be 18 decimals)
  address payable public wallet; // proceeds receiver
  address public paymentCurrency; // ETH sentinel or ERC20 address
  address public pointList; // optional allowance list

  mapping(address => uint256) public commitments; // payment committed per user
  mapping(address => uint256) public claimed; // tokens claimed per user
  mapping(address => uint256) public refunded; // payment refunded per user (to avoid double refunds)

  event AuctionDeployed(
    address funder,
    address token,
    address paymentCurrency,
    uint256 totalTokens,
    address admin,
    address wallet
  );
  event AuctionTimeUpdated(uint256 startTime, uint256 endTime);
  event AuctionPriceUpdated(uint256 rate, uint256 goal);
  event AuctionWalletUpdated(address wallet);
  event AuctionPointListUpdated(address pointList, bool enabled);
  event AddedCommitment(address addr, uint256 commitment);
  event AuctionFinalized();
  event AuctionCancelled();

  // --------------------------------------------------------
  // Init
  // --------------------------------------------------------

  function initProRataFixedPrice(
    address _funder,
    address _token,
    address _paymentCurrency,
    uint256 _totalTokens,
    uint256 _startTime,
    uint256 _endTime,
    uint256 _rate,
    uint256 _goal,
    address _admin,
    address _pointList,
    address payable _wallet
  ) public {
    require(_endTime < 10000000000, 'ProRata: use seconds timestamp');
    require(_startTime >= block.timestamp, 'ProRata: start before now');
    require(_endTime > _startTime, 'ProRata: end <= start');
    require(_rate > 0, 'ProRata: rate is 0');
    require(_wallet != address(0), 'ProRata: wallet is zero');
    require(_admin != address(0), 'ProRata: admin is zero');
    require(_totalTokens > 0, 'ProRata: total tokens is 0');
    require(IERC20(_token).decimals() == AUCTION_TOKEN_DECIMAL_PLACES, 'ProRata: token must be 18 decimals');
    if (_paymentCurrency != ETH_ADDRESS) {
      require(IERC20(_paymentCurrency).decimals() > 0, 'ProRata: payment not ERC20');
    }
    // ensure goal is achievable given totalTokens and rate
    uint256 maxC = _totalTokens.mul(_rate).div(AUCTION_TOKEN_DECIMALS);
    require(_goal <= maxC, 'ProRata: goal exceeds maxCommitment');

    marketPrice.rate = BoringMath.to128(_rate);
    marketPrice.goal = BoringMath.to128(_goal);

    marketInfo.startTime = BoringMath.to64(_startTime);
    marketInfo.endTime = BoringMath.to64(_endTime);
    marketInfo.totalTokens = BoringMath.to128(_totalTokens);

    auctionToken = _token;
    paymentCurrency = _paymentCurrency;
    wallet = _wallet;

    initAccessControls(_admin);

    _setList(_pointList);

    // Fund the auction with tokens
    _safeTransferFrom(_token, _funder, _totalTokens);

    emit AuctionDeployed(_funder, _token, _paymentCurrency, _totalTokens, _admin, _wallet);
    emit AuctionTimeUpdated(_startTime, _endTime);
    emit AuctionPriceUpdated(_rate, _goal);
  }

  // --------------------------------------------------------
  // Commitments
  // --------------------------------------------------------

  receive() external payable {
    revertBecauseUserDidNotProvideAgreement();
  }

  function marketParticipationAgreement() public pure returns (string memory) {
    return
      'I understand that I am interacting with a smart contract. I understand that commitments are subject to the token issuer and local laws where applicable. I have reviewed the code and understand it fully. I agree to not hold developers or other people associated with the project liable for any losses or misunderstandings';
  }

  function revertBecauseUserDidNotProvideAgreement() internal pure {
    revert('No agreement provided, please review the smart contract before interacting with it');
  }

  function commitEth(
    address payable _beneficiary,
    bool readAndAgreedToMarketParticipationAgreement
  ) public payable nonReentrant {
    require(paymentCurrency == ETH_ADDRESS, 'ProRata: payment not ETH');
    if (readAndAgreedToMarketParticipationAgreement == false) {
      revertBecauseUserDidNotProvideAgreement();
    }
    _addCommitment(_beneficiary, msg.value);
    require(marketStatus.commitmentsTotal <= address(this).balance, 'ProRata: committed exceeds balance');
  }

  function commitTokens(uint256 _amount, bool readAndAgreedToMarketParticipationAgreement) public {
    commitTokensFrom(msg.sender, _amount, readAndAgreedToMarketParticipationAgreement);
  }

  function commitTokensFrom(
    address _from,
    uint256 _amount,
    bool readAndAgreedToMarketParticipationAgreement
  ) public nonReentrant {
    require(paymentCurrency != ETH_ADDRESS, 'ProRata: payment not token');
    if (readAndAgreedToMarketParticipationAgreement == false) {
      revertBecauseUserDidNotProvideAgreement();
    }
    require(_amount > 0, 'ProRata: amount = 0');
    _safeTransferFrom(paymentCurrency, msg.sender, _amount);
    _addCommitment(_from, _amount);
  }

  function _addCommitment(address _addr, uint256 _commitment) internal {
    require(
      block.timestamp >= uint256(marketInfo.startTime) && block.timestamp <= uint256(marketInfo.endTime),
      'ProRata: outside hours'
    );
    require(!marketStatus.finalized, 'ProRata: finalized');
    require(_addr != address(0), 'ProRata: zero addr');
    uint256 newCommitment = commitments[_addr].add(_commitment);
    if (marketStatus.usePointList) {
      require(IPointList(pointList).hasPoints(_addr, newCommitment));
    }
    commitments[_addr] = newCommitment;
    marketStatus.commitmentsTotal = BoringMath.to128(uint256(marketStatus.commitmentsTotal).add(_commitment));
    emit AddedCommitment(_addr, _commitment);
  }

  // --------------------------------------------------------
  // Finalize & Withdraw
  // --------------------------------------------------------

  function withdrawTokens() public {
    withdrawTokens(msg.sender);
  }

  function withdrawTokens(address payable beneficiary) public nonReentrant {
    require(auctionEnded(), 'ProRata: not ended');
    require(marketStatus.finalized, 'ProRata: not finalized');

    uint256 userCommit = commitments[beneficiary];
    if (userCommit == 0) {
      return; // nothing to claim
    }

    if (auctionSuccessful()) {
      uint256 total = uint256(marketStatus.commitmentsTotal);
      uint256 maxC = maxCommitment();
      uint256 acceptedUser;
      if (total <= maxC) {
        acceptedUser = userCommit;
      } else {
        acceptedUser = userCommit.mul(maxC) / total;
      }

      // Tokens claimable
      uint256 entitledTokens = _getTokenAmount(acceptedUser);
      uint256 toClaim = entitledTokens.sub(claimed[beneficiary]);
      if (toClaim > 0) {
        claimed[beneficiary] = claimed[beneficiary].add(toClaim);
        _safeTokenPayment(auctionToken, beneficiary, toClaim);
      }

      // Refund surplus, if any
      uint256 refundEntitled = userCommit.sub(acceptedUser);
      uint256 toRefund = refundEntitled.sub(refunded[beneficiary]);
      if (toRefund > 0) {
        // Clamp refund to available balance to avoid ETH/Token transfer failure due to
        // rounding dust across pro‑rata allocation or unexpected prior withdrawals.
        if (paymentCurrency == ETH_ADDRESS) {
          uint256 bal = address(this).balance;
          if (toRefund > bal) {
            toRefund = bal;
          }
        } else {
          uint256 bal = IERC20(paymentCurrency).balanceOf(address(this));
          if (toRefund > bal) {
            toRefund = bal;
          }
        }
        if (toRefund > 0) {
          refunded[beneficiary] = refunded[beneficiary].add(toRefund);
          _safeTokenPayment(paymentCurrency, beneficiary, toRefund);
        }
      }
    } else {
      // Failed: refund full commitment once, then zero commitment
      require(block.timestamp > uint256(marketInfo.endTime), 'ProRata: not finished');
      // Clamp to available balance for safety
      uint256 toRefund = userCommit;
      if (paymentCurrency == ETH_ADDRESS) {
        uint256 bal = address(this).balance;
        if (toRefund > bal) {
          toRefund = bal;
        }
      } else {
        uint256 bal = IERC20(paymentCurrency).balanceOf(address(this));
        if (toRefund > bal) {
          toRefund = bal;
        }
      }
      if (toRefund > 0) {
        _safeTokenPayment(paymentCurrency, beneficiary, toRefund);
      }
      commitments[beneficiary] = 0;
    }
  }

  // --------------------------------------------------------
  // View: tokens claimable for a user (parity with other templates)
  // --------------------------------------------------------

  function tokensClaimable(address _user) public view returns (uint256) {
    uint256 userCommit = commitments[_user];
    if (userCommit == 0) {
      return 0;
    }
    // Only successful auctions distribute tokens
    if (!auctionSuccessful()) {
      return 0;
    }
    uint256 total = uint256(marketStatus.commitmentsTotal);
    uint256 maxC = maxCommitment();
    uint256 acceptedUser;
    if (total <= maxC) {
      acceptedUser = userCommit;
    } else if (total == 0) {
      acceptedUser = 0;
    } else {
      acceptedUser = userCommit.mul(maxC) / total;
    }
    uint256 entitled = _getTokenAmount(acceptedUser);
    uint256 claimable = entitled.sub(claimed[_user]);
    uint256 unclaimedTokens = IERC20(auctionToken).balanceOf(address(this));
    if (claimable > unclaimedTokens) {
      claimable = unclaimedTokens;
    }
    return claimable;
  }

  function finalize() public nonReentrant {
    require(
      hasAdminRole(msg.sender) || hasSmartContractRole(msg.sender) || wallet == msg.sender || finalizeTimeExpired(),
      'ProRata: sender must be admin'
    );
    require(marketInfo.totalTokens > 0, 'Not initialized');
    MarketStatus storage status = marketStatus;
    require(!status.finalized, 'ProRata: finalized');
    require(block.timestamp > uint256(marketInfo.endTime), 'ProRata: not ended');

    if (auctionSuccessful()) {
      uint256 total = uint256(status.commitmentsTotal);
      uint256 maxC = maxCommitment();
      uint256 acceptedTotal = total <= maxC ? total : maxC;
      uint256 tokensSold = _getTokenAmount(acceptedTotal);
      uint256 unsold = uint256(marketInfo.totalTokens).sub(tokensSold);

      if (acceptedTotal > 0) {
        _safeTokenPayment(paymentCurrency, wallet, acceptedTotal);
      }
      if (unsold > 0) {
        _safeTokenPayment(auctionToken, wallet, unsold);
      }
    } else {
      _safeTokenPayment(auctionToken, wallet, uint256(marketInfo.totalTokens));
    }

    status.finalized = true;
    emit AuctionFinalized();
  }

  function cancelAuction() public nonReentrant {
    require(hasAdminRole(msg.sender));
    MarketStatus storage status = marketStatus;
    require(!status.finalized, 'ProRata: finalized');
    require(uint256(status.commitmentsTotal) == 0, 'ProRata: already committed');
    _safeTokenPayment(auctionToken, wallet, uint256(marketInfo.totalTokens));
    status.finalized = true;
    emit AuctionCancelled();
  }

  // --------------------------------------------------------
  // Pricing & Status Views
  // --------------------------------------------------------

  function tokenPrice() public view returns (uint256) {
    return uint256(marketPrice.rate);
  }

  function _getTokenPrice(uint256 _tokens) internal view returns (uint256) {
    return _tokens.mul(uint256(marketPrice.rate)).div(AUCTION_TOKEN_DECIMALS);
  }

  function _getTokenAmount(uint256 _payment) internal view returns (uint256) {
    return _payment.mul(AUCTION_TOKEN_DECIMALS).div(uint256(marketPrice.rate));
  }

  function maxCommitment() public view returns (uint256) {
    return _getTokenPrice(uint256(marketInfo.totalTokens));
  }

  function auctionSuccessful() public view returns (bool) {
    return
      uint256(marketStatus.commitmentsTotal) >= uint256(marketPrice.goal) && uint256(marketStatus.commitmentsTotal) > 0;
  }

  function auctionEnded() public view returns (bool) {
    return block.timestamp > uint256(marketInfo.endTime);
  }

  function finalized() public view returns (bool) {
    return marketStatus.finalized;
  }

  function finalizeTimeExpired() public view returns (bool) {
    return uint256(marketInfo.endTime) + 7 days < block.timestamp;
  }

  // --------------------------------------------------------
  // Documents
  // --------------------------------------------------------

  function setDocument(string calldata _name, string calldata _data) external {
    require(hasAdminRole(msg.sender));
    _setDocument(_name, _data);
  }

  function setDocuments(string[] calldata _name, string[] calldata _data) external {
    require(hasAdminRole(msg.sender));
    uint256 numDocs = _name.length;
    for (uint256 i = 0; i < numDocs; i++) {
      _setDocument(_name[i], _data[i]);
    }
  }

  function removeDocument(string calldata _name) external {
    require(hasAdminRole(msg.sender));
    _removeDocument(_name);
  }

  // --------------------------------------------------------
  // Point List
  // --------------------------------------------------------

  function setList(address _list) external {
    require(hasAdminRole(msg.sender));
    _setList(_list);
  }

  function enableList(bool _status) external {
    require(hasAdminRole(msg.sender));
    marketStatus.usePointList = _status;
    emit AuctionPointListUpdated(pointList, marketStatus.usePointList);
  }

  function _setList(address _pointList) private {
    if (_pointList != address(0)) {
      pointList = _pointList;
      marketStatus.usePointList = true;
    }
    emit AuctionPointListUpdated(pointList, marketStatus.usePointList);
  }

  // --------------------------------------------------------
  // Setters
  // --------------------------------------------------------

  function setAuctionTime(uint256 _startTime, uint256 _endTime) external {
    require(hasAdminRole(msg.sender));
    require(_startTime < 10000000000, 'ProRata: use seconds');
    require(_endTime < 10000000000, 'ProRata: use seconds');
    require(_startTime >= block.timestamp, 'ProRata: start before now');
    require(_endTime > _startTime, 'ProRata: end <= start');
    require(marketStatus.commitmentsTotal == 0, 'ProRata: already started');
    marketInfo.startTime = BoringMath.to64(_startTime);
    marketInfo.endTime = BoringMath.to64(_endTime);
    emit AuctionTimeUpdated(_startTime, _endTime);
  }

  function setAuctionPrice(uint256 _rate, uint256 _goal) external {
    require(hasAdminRole(msg.sender));
    require(_rate > 0, 'ProRata: rate is 0');
    require(marketStatus.commitmentsTotal == 0, 'ProRata: already started');
    // ensure new goal is achievable with current totalTokens and new rate
    uint256 maxC = uint256(marketInfo.totalTokens).mul(_rate).div(AUCTION_TOKEN_DECIMALS);
    require(_goal <= maxC, 'ProRata: goal exceeds maxCommitment');
    marketPrice.rate = BoringMath.to128(_rate);
    marketPrice.goal = BoringMath.to128(_goal);
    emit AuctionPriceUpdated(_rate, _goal);
  }

  function setAuctionWallet(address payable _wallet) external {
    require(hasAdminRole(msg.sender));
    require(_wallet != address(0), 'ProRata: wallet zero');
    wallet = _wallet;
    emit AuctionWalletUpdated(_wallet);
  }

  // --------------------------------------------------------
  // Market Launchers
  // --------------------------------------------------------

  function init(bytes calldata) external payable override {}

  function initMarket(bytes calldata _data) public override {
    (
      address _funder,
      address _token,
      address _paymentCurrency,
      uint256 _totalTokens,
      uint256 _startTime,
      uint256 _endTime,
      uint256 _rate,
      uint256 _goal,
      address _admin,
      address _pointList,
      address payable _wallet
    ) = abi.decode(
        _data,
        (address, address, address, uint256, uint256, uint256, uint256, uint256, address, address, address)
      );
    initProRataFixedPrice(
      _funder,
      _token,
      _paymentCurrency,
      _totalTokens,
      _startTime,
      _endTime,
      _rate,
      _goal,
      _admin,
      _pointList,
      _wallet
    );
  }

  function getProRataInitData(
    address _funder,
    address _token,
    address _paymentCurrency,
    uint256 _totalTokens,
    uint256 _startTime,
    uint256 _endTime,
    uint256 _rate,
    uint256 _goal,
    address _admin,
    address _pointList,
    address payable _wallet
  ) external pure returns (bytes memory _data) {
    return
      abi.encode(
        _funder,
        _token,
        _paymentCurrency,
        _totalTokens,
        _startTime,
        _endTime,
        _rate,
        _goal,
        _admin,
        _pointList,
        _wallet
      );
  }

  // --------------------------------------------------------
  // Minimal view helpers for UI parity
  // --------------------------------------------------------

  function getBaseInformation() external view returns (address, uint64, uint64, bool) {
    return (auctionToken, marketInfo.startTime, marketInfo.endTime, marketStatus.finalized);
  }

  function getTotalTokens() external view returns (uint256) {
    return uint256(marketInfo.totalTokens);
  }
}
