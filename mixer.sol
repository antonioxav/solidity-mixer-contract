// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;

contract Mixer {

    enum Role {
        Participant,
        Banker,
        Blacklisted
    } // bankers get the same priviledges as participcants

    enum MaskedCDStatus {
        NotSubmitted,
        Unsigned,
        Signed
    }

    struct RSAPublicKey {
        uint128 e; // public exponent
        uint128 n; // modulus
    }

    struct AccountDetails {
        Role role;
        uint256 locked_balance; // TODO: remove and only use deposit
        uint256 balance;
        uint256 bankerID; // index in bankers array. Only bankers have this
        RSAPublicKey bankerPK;
        uint128 lastMaskedCD; // last maskedCD deposited by this account
        // ? uint lastRequestCycle
    }

    struct Cycle {
        address banker; // current banker
        bool bankerCheated;
        uint256 initBlock;
        uint256 depositDeadline;
        uint256 requestDeadline;

        address[] depositors;
        address[] claimants;
        address[] intermediaries;

        mapping(uint128 => MaskedCDDetails) maskedCDDetails;
        mapping(uint128 => ClaimedCDDetails) claimedCDDetails; // has CD been claimed
    }

    struct MaskedCDDetails {
        MaskedCDStatus status;
        uint256 cycleEnd; // * Cycle End blocks are used as unique identifiers for each cycle
        address depositor; 
        uint128 signed;
    }

    struct ClaimedCDDetails {
        uint256 cycleEnd; // * Cycle End blocks are used as unique identifiers for each cycle
        address claimant;
    }
    // // state variables
    // address public currentBanker; // current banker
    // uint public cycleInitBlock;
    // uint public cycleDepositDeadline;
    // uint public cycleRequestDeadline;

    address[] public bankers;
    mapping(address => AccountDetails) accountDetails;
    Cycle cycle;
    // mapping (bytes32 => MaskedCDDetails) maskedCDDetails;
    // mapping (bytes32 => address) maskedCDBanker;

    // mapping (bytes32 => MaskedCDStatus) maskedCDStatus;
    // mapping (bytes32 => bytes32) signedMaskedCD;
    // mapping (bytes32 => address) maskedCDDepositor;
    // mapping (bytes32 => bool) isClaimed;
    // mapping (address => uint) balance;
    // mapping (bytes32 => bool) signedMaskedCD;

    uint256 signingFee = 0.1 ether;
    uint256 claimFee = 0.1 ether;
    uint256 transferFee = 0.1 ether;
    uint256 bankerDeposit = 10 ether;
    uint64 maxDeposits = 50;

    event newCycleEvent(
        address newBanker,
        uint256 cycleInitBlock,
        uint256 cycleDepositDeadline,
        uint256 cycleRequestDeadline
    );

    event blacklistEvent(address cheater);

    constructor(RSAPublicKey memory bankerPK) payable {
        registerBanker(bankerPK);
        resetCycle();
    }

    modifier bankersOnly() {
        require(accountDetails[msg.sender].role == Role.Banker);
        _;
    }

    modifier allParticipants() {
        require(accountDetails[msg.sender].role != Role.Blacklisted);
        _;
    }

    function resetCycle() private {
        require(bankers.length>0, "Awaiting bankers");

        // distribute last cycle's deposits
        if (!cycle.bankerCheated) {
            for (uint16 d = 0; d < cycle.depositors.length; d++) {
                accountDetails[cycle.depositors[d]].balance -= 1 ether;
                if (d < cycle.claimants.length) {
                    accountDetails[cycle.claimants[d]].balance += 1 ether - claimFee;
                    accountDetails[cycle.intermediaries[d]].balance += claimFee;
                }
            }
        }

        delete cycle.depositors;
        delete cycle.claimants;

        // new deadlines
        cycle.initBlock = block.number;
        uint256 day = (24 * 60 * 60) / uint256(13);
        cycle.depositDeadline = cycle.initBlock + day;
        cycle.requestDeadline = cycle.depositDeadline + day;

        // new banker
        uint256 currentBankerID = accountDetails[cycle.banker].bankerID;
        cycle.banker = bankers[(currentBankerID + 1) % bankers.length];
        cycle.bankerCheated = false;

        emit newCycleEvent(
            cycle.banker,
            cycle.initBlock,
            cycle.depositDeadline,
            cycle.requestDeadline
        );
    }

    function getBankerPK() public view returns (RSAPublicKey memory){
        return accountDetails[cycle.banker].bankerPK;
    }

    function registerBanker(RSAPublicKey memory pk) public payable {
        require(
            accountDetails[msg.sender].role == Role.Participant,
            "You are either already a banker or you are blacklisted"
        );
        require(msg.value >= bankerDeposit);
        
        accountDetails[msg.sender].bankerID = bankers.length;
        bankers.push(msg.sender);
        accountDetails[msg.sender].role = Role.Banker;
        accountDetails[msg.sender].bankerPK = pk;
        accountDetails[msg.sender].locked_balance += msg.value;
    }

    function deregisterBanker() external bankersOnly {
        address banker = msg.sender;
        require(accountDetails[banker].role == Role.Banker, "You are not a banker");
        require(cycle.banker!=banker, "current banker cannot deregister");

        uint256 bankerID = accountDetails[banker].bankerID;
        
        // remove banker from bankers
        accountDetails[banker].role = Role.Participant;
        bankers[bankerID] = bankers[bankers.length - 1]; 
        bankers.pop();

        // re-assign bankerID
        delete accountDetails[banker].bankerID;
        accountDetails[bankers[bankerID]].bankerID = bankerID; 

        // return deposit
        accountDetails[banker].balance += accountDetails[banker].locked_balance;
        accountDetails[banker].locked_balance = 0;

        delete accountDetails[banker].bankerPK;
    }

    function blacklist(address cheater) private {
        require(accountDetails[cheater].role != Role.Blacklisted);

        if (accountDetails[cheater].role == Role.Banker) {
            uint256 bankerID = accountDetails[cheater].bankerID;
            bankers[bankerID] = bankers[bankers.length - 1]; // remove cheater from bankers
            bankers.pop();
            accountDetails[bankers[bankerID]].bankerID = bankerID; // re-assign bankerID
        }
        accountDetails[cheater].role = Role.Blacklisted;
        delete accountDetails[cheater].locked_balance;
        delete accountDetails[cheater].balance;
        emit blacklistEvent(cheater);
    }

    function verifySignature(
        uint128 message, // sha256 hashed message % n
        uint128 sign, // message**d % n
        RSAPublicKey memory pk
    ) public pure returns (bool) { // TODO: change to internal later?
        
        uint n = uint(pk.n);
        uint exp = uint(pk.e);
        uint base = uint(sign) % n;
        uint unsignedMessage = 1;

        while (exp > 0){
            if ((exp & 1) > 0) unsignedMessage = (unsignedMessage * base) % n;
            exp >>= 1;
            base = (base**2) % n;
        }

        return (unsignedMessage == uint(message));
    }

    function depositEther(uint128 maskedCD) external payable allParticipants {
        if (block.number > cycle.requestDeadline) resetCycle();
        else
            require(
                block.number <= cycle.depositDeadline,
                "Not in the deposit phase. Please try during next cycle."
            );

        require(
            msg.value >= (1 ether + signingFee),
            "Please submit at least 1.1 ether"
        );

        // If same maskedCD has not been used this cycle, then initialize it, else revert
        if (cycle.maskedCDDetails[maskedCD].cycleEnd != cycle.requestDeadline)
            cycle.maskedCDDetails[maskedCD] = MaskedCDDetails(
                MaskedCDStatus.Unsigned,
                cycle.requestDeadline,
                msg.sender,
                0
            );
        else
            revert(
                "A maskedCD with the same value has already been submitted in this cycle"
            );

        // require(
        //     cycle.maskedCDDetails[maskedCD].status == MaskedCDStatus.NotSubmitted,
        //     "A maskedCD with the same value has already been submitted in this cycle"
        // );

        accountDetails[msg.sender].balance += 1 ether + signingFee; // * refundable until signed
        accountDetails[msg.sender].lastMaskedCD = maskedCD;
    }

    function signMaskedCD(uint128 maskedCD, uint128 sign) external bankersOnly {
        if (block.number > cycle.requestDeadline) resetCycle();
        else
            require(
                block.number <= cycle.depositDeadline,
                "Not in the deposit phase."
            );

        require(
            cycle.banker == msg.sender,
            "You are not the banker for this cycle"
        );
        require(
            cycle.maskedCDDetails[maskedCD].cycleEnd == cycle.requestDeadline &&
                cycle.maskedCDDetails[maskedCD].status ==
                MaskedCDStatus.Unsigned,
            "Invalid Unsigned MaskedCD"
        );

        require(verifySignature(maskedCD, sign, accountDetails[msg.sender].bankerPK), "Signature mismatch");

        require(
            cycle.depositors.length <= maxDeposits,
            "Maximum number of deposits for this cycle have been signed"
        );

        cycle.maskedCDDetails[maskedCD].signed = sign;
        cycle.maskedCDDetails[maskedCD].status = MaskedCDStatus.Signed;
        address depositor = cycle.maskedCDDetails[maskedCD].depositor;
        cycle.depositors.push(depositor);

        // pay banker signing fees
        accountDetails[depositor].balance -= signingFee;
        accountDetails[cycle.banker].balance += signingFee;
    }

    function bankerCheated() internal {
        // Blacklist Banker
        cycle.bankerCheated = true;

        // distribute all of the banker's money.
        uint256 compensation = (accountDetails[cycle.banker].locked_balance +
            accountDetails[cycle.banker].balance) /
            cycle.depositors.length;
        for (uint16 d = 0; d < cycle.depositors.length; d++)
            accountDetails[cycle.depositors[d]].balance += compensation;

        // resetCycle
        blacklist(cycle.banker);
        resetCycle();
        // ! old depositors can collect their money now
    }

    function requestWithdrawal(
        uint128 signedCD,
        uint nonce,
        address claimant
    ) external allParticipants {
        require(
            block.number <= cycle.requestDeadline,
            "Deadline to request withdrawal has passed."
        );
        require(
            block.number > cycle.depositDeadline,
            "Still in the deposit phase"
        );

        require(cycle.claimants.length <= cycle.depositors.length); // TODO: remove if redundant

        RSAPublicKey memory bankerPK = accountDetails[cycle.banker].bankerPK;
        uint128 CD = uint128(uint256(sha256(abi.encodePacked(nonce, claimant)))) % bankerPK.n;
        require(
            verifySignature(
                CD,
                signedCD,
                bankerPK
            ),
            "Signature mismatch"
        );

        if (cycle.claimedCDDetails[signedCD].cycleEnd != cycle.requestDeadline)
            cycle.claimedCDDetails[signedCD] = ClaimedCDDetails(
                cycle.requestDeadline,
                claimant
            );
        else revert("This signedCD has already been claimed");

        cycle.claimants.push(claimant);
        cycle.intermediaries.push(msg.sender);

        if (cycle.claimants.length > cycle.depositors.length) bankerCheated();
    }

    function transferMoney(address payee) external allParticipants {
        require(accountDetails[payee].balance > 0);
        require(accountDetails[payee].role != Role.Blacklisted);
        require(
            payee != cycle.banker,
            "Bankers cannot withdraw during their cycle"
        );

        // Prevent depositors from getting a refund after getting their MaskedCD signed
        // if made deposit this cycle and withdrew, then re-initialize maskedCDDetails
        MaskedCDDetails memory lastMaskedCDDetails = cycle.maskedCDDetails[accountDetails[payee].lastMaskedCD];
        if (lastMaskedCDDetails.cycleEnd == cycle.requestDeadline) {
            require(
                lastMaskedCDDetails.status != MaskedCDStatus.Signed,
                "Accounts with signed maskedCDs cannot withdraw in the same cycle"
            );
            if (lastMaskedCDDetails.status == MaskedCDStatus.Unsigned)
                delete cycle.maskedCDDetails[accountDetails[payee].lastMaskedCD];
        }

        // Pay Intermediary (balance, not actual transfer). check if payee can afford fees
        if (payee!=msg.sender) {
            require(accountDetails[payee].balance > transferFee);
            accountDetails[payee].balance -= transferFee;
            accountDetails[msg.sender].balance += transferFee;
        }


        uint amount = accountDetails[payee].balance;
        accountDetails[payee].balance = 0;
        (bool sent, ) = payable(payee).call{value: amount}("");
        require(sent, "Failed to send Ether");
    }
}
