// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.5.0/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.5.0/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.5.0/contracts/utils/Counters.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/v4.5.0/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./RewardToken.sol";

contract TamagotchiERC is ERC721Enumerable, ReentrancyGuard, Ownable {
    using Counters for Counters.Counter;
    Counters.Counter private _tokenIdCounter;

    RewardToken public rewardToken;
    mapping(uint256 => uint256) public tokenMintTimestamps;
    mapping(uint256 => uint256) public claimCounts;
    mapping(uint256 => string) private _evolvedURIs;
    mapping(uint256 => bool) public hasEvolved;

    string private _baseTokenURI;
    uint256 public evolvedCount;
    bytes32 public merkleRoot;
    uint256 public HOLDING_PERIOD = 6 hours; 
    uint256 public constant REWARD_AMOUNT = 100 * (10 ** 18);
    uint256 public constant EVOLVED_REWARD_AMOUNT = 300 * (10 ** 18);

    uint256 public constant initialClaimAmount = 2000 * (10 ** 18);

    mapping(uint256 => bool) public hasClaimedInitialAmount;
    uint256 public evolveInterval = 800;
    bool public gameStarted = false;
  
    uint256 public constant MINT_PRICE = 0.012 ether;
    uint256 public constant WL_MINT_PRICE = 0.006 ether;
    uint256 public constant MAX_MINT_PER_WALLET = 100;
    uint256 public constant MAX_MINT_AT_ONCE = 20;
    uint256 public constant MAX_WL_MINT_PER_WALLET = 5;
    uint256 public constant MAX_WL_MINT_AT_ONCE = 5;
    uint256 constant public MAX_TIME_DURATION = 1 hours;
    mapping(address => uint256) public mintedPerWallet;
    bool public mintingOpen = false;

    constructor() ERC721("Virtual Pets", "VPET") Ownable() {}


    function isValidTimestamp(uint256 _timestamp) internal view returns (bool) {
        uint256 currentBlockTime = block.timestamp;
        uint256 currentBlockStart = currentBlockTime - (currentBlockTime % MAX_TIME_DURATION);
        uint256 currentBlockEnd = currentBlockStart + MAX_TIME_DURATION;

        if (_timestamp >= currentBlockStart && _timestamp < currentBlockEnd) {
            return true;
        } else {
            return false;
        }
    }

    // Function to set the rewardToken contract address
    function setRewardToken(address _rewardTokenAddress) public onlyOwner {
        require(address(rewardToken) == address(0), "RewardToken contract address already set");
        rewardToken = RewardToken(_rewardTokenAddress);
    }

    function setBaseTokenURI(string memory baseTokenURI) public onlyOwner {
        _baseTokenURI = baseTokenURI;
    }

    function startGame() public onlyOwner {
        gameStarted = true;
    }

    function openMint() public onlyOwner {
        mintingOpen = true;
    }

    function mintNFT(uint256 quantity) public payable {
        require(mintingOpen, "Minting is closed");
        require(quantity > 0 && quantity <= MAX_MINT_AT_ONCE, "Cannot mint specified number at once");
        require(mintedPerWallet[msg.sender] + quantity <= MAX_MINT_PER_WALLET, "Exceeds maximum per wallet");
        require(msg.value >= MINT_PRICE * quantity, "Ether sent is not correct");
        
        for (uint256 i = 0; i < quantity; i++) {
            _tokenIdCounter.increment();
            uint256 tokenId = _tokenIdCounter.current();
            _mint(msg.sender, tokenId);
            tokenMintTimestamps[tokenId] = block.timestamp;
            claimCounts[tokenId] = 0;
        }

        mintedPerWallet[msg.sender] += quantity; 
    }

    function whitelistMint(uint256 quantity, bytes32[] calldata merkleProof) public payable {
        require(mintingOpen, "Minting is closed");
        require(quantity > 0 && quantity <= MAX_WL_MINT_AT_ONCE, "Cannot mint specified number at once");
        require(mintedPerWallet[msg.sender] + quantity <= MAX_WL_MINT_PER_WALLET, "Exceeds maximum whitelist mint per wallet");
        require(msg.value >= WL_MINT_PRICE * quantity, "Ether sent is not correct");
        
        // Verify the Merkle Proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        require(MerkleProof.verify(merkleProof, merkleRoot, leaf), "Invalid Merkle Proof");

        for (uint256 i = 0; i < quantity; i++) {
            _tokenIdCounter.increment();
            uint256 tokenId = _tokenIdCounter.current();
            _mint(msg.sender, tokenId);
            tokenMintTimestamps[tokenId] = block.timestamp;
            claimCounts[tokenId] = 0;
        }

        mintedPerWallet[msg.sender] += quantity;
    }


    function claimAllRewards() public nonReentrant {
        require(gameStarted, "Game has not started yet");
        
        uint256 ownerTokenCount = balanceOf(msg.sender);
        require(ownerTokenCount > 0, "No NFTs owned.");
        uint256 totalReward = 0;

        for (uint256 i = 0; i < ownerTokenCount; i++) {
            uint256 tokenId = tokenOfOwnerByIndex(msg.sender, i);
            if (!hasClaimedInitialAmount[tokenId] || block.timestamp >= tokenMintTimestamps[tokenId] + HOLDING_PERIOD) {
                tokenMintTimestamps[tokenId] = block.timestamp;
                uint256 rewardAmount;
                if (!hasClaimedInitialAmount[tokenId]) {
                    rewardAmount = initialClaimAmount;
                    hasClaimedInitialAmount[tokenId] = true;
                } else {
                    rewardAmount = hasEvolved[tokenId] ? EVOLVED_REWARD_AMOUNT : REWARD_AMOUNT;
                }
                totalReward += rewardAmount;
                claimCounts[tokenId] += 1;

                if (claimCounts[tokenId] >= 5) {
                    evolve(tokenId);
                }
            }
        }
        require(totalReward > 0, "No rewards available to claim.");
        bool sent = rewardToken.transfer(msg.sender, totalReward);
        require(sent, "Reward token transfer failed.");
    }


    function setEvolvedMetadata(uint256 tokenId, string memory evolvedURI) public onlyOwner {
        require(_exists(tokenId), "Token does not exist");
        _evolvedURIs[tokenId] = evolvedURI;
    }

    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override {
        super._beforeTokenTransfer(from, to, tokenId); // Call parent hook
        if (from != address(0) && to != address(0) && !hasEvolved[tokenId]) {
            // Only reset claim counts if the NFT hasn't evolved
            claimCounts[tokenId] = 0;
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        require(_exists(tokenId), "ERC721Metadata: URI query for nonexistent token");

        if (bytes(_evolvedURIs[tokenId]).length > 0) {
            return _evolvedURIs[tokenId];
        }

        return string(abi.encodePacked(_baseTokenURI, Strings.toString(tokenId)));
    }

 
    function setEvolveInterval(uint256 interval) public onlyOwner {
        evolveInterval = interval;
    }

   function evolve(uint256 tokenId) public {
        require(ownerOf(tokenId) == msg.sender, "Caller is not the owner");
        require(claimCounts[tokenId] >= 5, "Not enough claims to evolve");
        require(isValidTimestamp(block.timestamp), "Invalid timestamp"); 
        
        string memory evolvedURI = _evolvedURIs[tokenId];        
        _evolvedURIs[tokenId] = evolvedURI;
        hasEvolved[tokenId] = true;
        evolvedCount += 1;
        
        if (evolvedCount % evolveInterval == 0) {
            HOLDING_PERIOD += 6 hours;
        }
    }

    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No Ether left to withdraw");
        (bool sent, ) = owner().call{value: balance}("");
        require(sent, "Failed to send Ether");
    }

    function setMerkleRoot(bytes32 _merkleRoot) public onlyOwner {
        merkleRoot = _merkleRoot;
    }

}
