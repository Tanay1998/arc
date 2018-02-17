pragma solidity ^0.4.19;

import "./UniversalScheme.sol";
import "../controller/Reputation.sol";
import "../controller/DAOToken.sol";
import "zeppelin-solidity/contracts/ownership/Ownable.sol";
import "zeppelin-solidity/contracts/math/SafeMath.sol";
import "zeppelin-solidity/contracts/lifecycle/Destructible.sol";


/**
 * @title An avatar contract for ICO.
 * @dev Allow people to donate by simply sending ether to an address.
 */
contract MirrorContractICO is Destructible {
    Avatar public organization; // The organization address (the avatar)
    SimpleICO public simpleICO;  // The ICO contract address
    /**
    * @dev Constructor, setting the organization and ICO scheme.
    * @param _organization The organization's avatar.
    * @param _simpleICO The ICO Scheme.
    */
    function MirrorContractICO(Avatar _organization, SimpleICO _simpleICO) public {
        organization = _organization;
        simpleICO = _simpleICO;
    }

    /**
    * @dev Fallback function, when ether is sent it will donate to the ICO.
    * The ether will be returned if the donation is failed.
    */
    function () public payable {
        // Not to waste gas, if no value.
        require(msg.value != 0);

        // Return ether if couldn't donate.
        if (simpleICO.donate.value(msg.value)(organization, msg.sender) == 0) {
            revert();
        }
    }
}


/**
 * @title SimpleICO scheme.
 * @dev A universal scheme to allow organizations to open a simple ICO and get donations.
 */
contract SimpleICO is UniversalScheme {
    using SafeMath for uint;

    // Struct holding the data for each organization
    struct Organization {
        bytes32 paramsHash; // Save the parameters approved by the org to open the ICO, so reuse of ICO will not change.
        address avatarContractICO; // Avatar is a contract for users that want to send ether without calling a function.
        uint totalEthRaised;
        bool isHalted; // The admin of the ICO can halt the ICO at any time, and also resume it.
        Reputation rep;
        DAOToken token;
    }

    mapping (bytes32 => (address => uint)) deposits;
    mapping (bytes32 => (address => uint)) withdrawAmount;

    // A mapping from hashes to parameters (use to store a particular configuration on the controller)
    struct Parameters {
        uint cap; // Cap in Eth
        uint price; // Price represents Tokens per 1 Eth
        uint startBlock;
        uint endBlock;
        address beneficiary; // all funds received will be transferred to this address.
        address admin; // The admin can halt or resume ICO.
        uint status; // 0 = inactive, 1 = active, 2 = closed + successful, 3 = closed + failed
    }

    // A mapping from the organization (Avatar) address to the saved data of the organization:
    mapping(address=>Organization) public organizationsICOInfo;

    mapping(bytes32=>Parameters) public parameters;

    event DonationReceived(address indexed organization, address indexed _beneficiary, uint _incomingEther, uint indexed _tokensAmount);

    /**
     * @dev Constructor
     */
    function SimpleICO() public {}

    /**
    * @dev Hash the parameters, save them if necessary, and return the hash value
    * @param _cap the ico cap
    * @param _price  represents Tokens per 1 Eth
    * @param _startBlock  ico start block
    * @param _endBlock ico end
    * @param _beneficiary the ico ether beneficiary
    * @param _admin the address of the ico admin which can hold and resume the ICO.
    * @return bytes32 -the params hash
    */
    function setParameters(
        uint _cap,
        uint _price,
        uint _startBlock,
        uint _endBlock,
        address _beneficiary,
        address _admin
    )
        public
        returns(bytes32)
    {
        bytes32 paramsHash = getParametersHash(
            _cap,
            _price,
            _startBlock,
            _endBlock,
            _beneficiary,
            _admin
        );
        if (parameters[paramsHash].cap == 0) {
            parameters[paramsHash] = Parameters({
                cap: _cap,
                price: _price,
                startBlock: _startBlock,
                endBlock:_endBlock,
                beneficiary:_beneficiary,
                admin:_admin
            });
        }
        return paramsHash;
    }

    /**
    * @dev Hash the parameters and return the hash value
    * @param _cap the ico cap
    * @param _price  represents Tokens per 1 Eth
    * @param _startBlock  ico start block
    * @param _endBlock ico end
    * @param _beneficiary the ico ether beneficiary
    * @param _admin the address of the ico admin which can hold and resume the ICO.
    * @return bytes32 -the params hash
    */
    function getParametersHash(
        uint _cap,
        uint _price,
        uint _startBlock,
        uint _endBlock,
        address _beneficiary,
        address _admin
    )
        public
        pure
        returns(bytes32)
   {
        return (keccak256(
            _cap,
            _price,
            _startBlock,
            _endBlock,
            _beneficiary,
            _admin
        ));
    }

    /**
     * @dev start an ICO
     * @param _avatar The Avatar's of the organization
     */
    function start(Avatar _avatar, string _tokenName, string _tokenSymbol) public {
        require(!isActive(_avatar));

        Organization memory org;

        org.paramsHash = getParametersFromController(_avatar);
        Parameters storage params = parameters[org.paramsHash];
        require(params.cap != 0);
        require(params.status == 0);
        params.status = 1;

        org.avatarContractICO = new MirrorContractICO(_avatar, this);
        organizationsICOInfo[_avatar] = org;

        org.rep = new Reputation();
        org.token = new DAOToken(_tokenName, _tokenSymbol);
        ControllerInterface controller = ControllerInterface(_avatar.owner());
        org.rep.transferOwnership(controller);
    }

    function close(Avatar _avatar) public {
        Organization memory org = organizationsICOInfo[_avatar];

        // storage gets it as reference so updating params changes the mapping object
        Parameters storage params = parameters[org.paramsHash];

        // Shouldn't have closed it yet, also should have started
        require (params.status == 1);

        // Should've started
        if (block.number <= params.startBlock) {
            return false;
        }

        // Can't end right now. There's time left and also haven't raised all the money
        if (block.number <= params.endBlock && org.totalEthRaised < params.cap) {
            return false;
        }
        
        /*
            Ready to finish: either fully raised or finished time period (or both)
        */ 

        // This is great because now we can send money to the beneficiary
        if (org.totalEthRaised >= params.cap) {
            if (!params.beneficiary.transfer(org.totalEthRaised)) {
                // Fail if can't send money to beneficiary
                revert();
            }
            params.status = 2; 
        } else {
            params.status = 3;
        }
        
        return true;
    }

    function withdraw(address) public {
        Organization memory org = organizationsICOInfo[_avatar];
        Parameters memory params = parameters[org.paramsHash];

        // Send back excess amounts
        if (params.status == 2 || params.status == 3) {
            var amount = withdrawAmount[org.paramsHash][msg.sender];
            withdrawAmount[org.paramsHash][msg.sender] = 0;
            if (!msg.sender.transfer(amount)) {
                withdrawAmount[org.paramsHash][msg.sender] = amount;
            }
        } 

        // Send back donations if failed. 
        if (params.status == 3) {
            var amount = deposits[org.paramsHash][msg.sender];
            deposits[org.paramsHash][msg.sender] = 0;
            if (!msg.sender.transfer(amount)) {
                deposits[org.paramsHash][msg.sender] = amount;
            }
        }
    }


    /**
     * @dev Allowing admin to halt an ICO.
     * @param _avatar The Avatar's of the organization
     */
    function haltICO(address _avatar) public {
        require(msg.sender == parameters[organizationsICOInfo[_avatar].paramsHash].admin);
        organizationsICOInfo[_avatar].isHalted = true;
    }

    /**
     * @dev Allowing admin to reopen an ICO.
     * @param _avatar The Avatar's of the organization
     */
    function resumeICO(address _avatar) public {
        require(msg.sender == parameters[organizationsICOInfo[_avatar].paramsHash].admin);
        organizationsICOInfo[_avatar].isHalted = false;
    }

    /**
     * @dev Check is an ICO is active (halted is still considered active). Active ICO:
     * 1. The organization is registered.
     * 2. The ICO didn't reach it's cap yet.
     * 3. The current block isn't bigger than the "endBlock" & Smaller then the "startBlock"
     * @param _avatar The Avatar's of the organization
     * @return bool which represents a successful of the function
     */
    function isActive(address _avatar) public view returns(bool) {
        Organization memory org = organizationsICOInfo[_avatar];
        Parameters memory params = parameters[org.paramsHash];

        if (params.status != 1) {
            return false;
        }

        if (org.totalEthRaised >= params.cap) {
            return false;
        }
        if (block.number >= params.endBlock) {
            return false;
        }
        if (block.number <= params.startBlock) {
            return false;
        }

        return true;
    }

    /**
     * @dev Donating ethers to get tokens.
     * If the donation is higher than the remaining ethers in the "cap",
     * The donator will get the change in ethers.
     * @param _avatar The Avatar's of the organization.
     * @param _beneficiary The donator's address - which will receive the ICO's tokens.
     * @return bool which represents a successful of the function
     */
    function donate(Avatar _avatar, address _beneficiary) public payable returns(uint) {
        Organization memory org = organizationsICOInfo[_avatar];
        Parameters memory params = parameters[org.paramsHash];

        // Check ICO is active:
        require(isActive(_avatar));

        // Check ICO is not halted:
        require(!org.isHalted);

        uint incomingEther;
        uint change = 0;

        if ( msg.value > (params.cap).sub(org.totalEthRaised) ) {
            incomingEther = (params.cap).sub(org.totalEthRaised);
            change = (msg.value).sub(incomingEther);
        } else {
            incomingEther = msg.value;
        }
        uint tokens = 1;
        
        deposits[org.paramsHash][msg.sender] += incomingEther;
        withdrawAmount[orgs.paramsHash][msg.sender] += change;

        org.token.mint(msg.sender, tokens);
        org.rep.mint(msg.sender, incomingEther);

        // Update total raised, call event and return amount of tokens bought:
        organizationsICOInfo[_avatar].totalEthRaised += incomingEther;
        DonationReceived(_avatar, _beneficiary, incomingEther, tokens);
        return tokens;
    }
}
