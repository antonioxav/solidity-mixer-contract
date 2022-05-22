# Decentralized Mixer Based on RSA Blind Signatures

## Protocol

### Actors

There are four kinds of actors in this mixer contract:
 - <u>Depositors</u>: They deposit money (1ether + fees) and submit Masked Certificate Deposits for signing.
 - <u>Claimants</u>: They are the intended receipients of the deposits made by Depositors. They can (either directly or through an Intermediary) submit Signed Certificate Deposits to request withdrawal.
 - <u>Intermediaries</u>: They can help Claimants who lack funds to request withdrawals and transfer money to their accounts. They receive a claim or transfer fee for their services.
 - <u>Bankers</u>: They are responsible for signing Masked Certificate Deposits and thus, facilitating the mixing process. They receive a signing fee for their services.

 All accounts on the blockchain are, by default, considered participants in the contract and have access to the Depositor, Claimant and Intermediary roles. Furthermore, any participant can apply to be a banker (in addition to all the aforementioned roles) by submiting a security deposit of 10ETH and by providing an RSA public key (which includes the public exponent and modulus), that they posses the corresponding private key of. Bankers can de-register to give up the Banker role and receive their deposit back. Bankers can also update their RSA public key at any time by calling `updateKey(newPK)`. Bankers are encouraged to update their keys after every cycle of being a banker for security purposes.

 The account that deploys a contract is forced to register as a banker.

 All accounts have their balances stored in the contract. They can receive any of their money held by the contract by calling the `transferMoney(address payee)` function.

 Some bankers can be blacklisted if found cheating. Blacklisted participants lose access to any funds (and deposits) held by the contract. Furthermore, they lose access to all of the roles defined above.

 ### Cycles
 The protocol is executed in cycles that last a maximum of 2 days each and consists of two phases (Deposit, Request). New cycles start automatically at the beginning of the contract or when the banker is caught cheating. Otherwise, they can be manually reset by calling `resetCycle()` once the cycle's request phase deadline has passed or if the deposit phase is over and there were no Masked CDs signed. At the beginning of each cycle:
 - An account that previously registered as a banker is designated as the Cycle Banker. There is only one account that is allowed to execute the duties of a banker during each cycle. Every cycle a different registered banker gets the chance to become the Cycle Banker. The Cycle Banker cannot be the payee in the `transferMoney()` function during their cycle. The Cycle Banker cannot call `deregisterAsBanker()` during their cycle.
 - The Cycle Banker's Public Key at the time of designation becomes the public key to be used throughout the cycle (even if the Cycle Banker calls `updateKey()`)
 - All Certificate Deposits signed in previous cycles become void and thus, cannot be used to request withdrawal.
 - All Masked Certificate Deposits submitted by depositors in the previous cycle become void and cannot be signed by the Cycle Banker.
 - If the Cycle Banker of the last cycle did not cheat, then all requested claimant withdrawals and claimFees for the intermediaries from that cycle are deposited in the account balances of their respective receipients. Those receipients can call `transferMoney()` to transfer their balance to their actual accounts.
 
 The first cycle starts as soon as the contract is deployed with the account that deployed the contract being the first Cycle Banker. Each cycle is uniquely identified by the block.number of its end deadline i.e. the deadline of the request phase.

### Phases
#### <b><u>Deposit Phase (24 hours)</b></u>
1. A Depositor can call the `depositEther(maskedCD)` function to deposit 1 ether along with a Masked Certificate Deposit for signature. The depositor must pay 1 ether + signing fees to the function. The deposit will only be worth 1 ether irrespective of the amount paid to the function. Any extra money paid will be kept by the contract. A depositor can construct a Masked Certificate Deposit using the following function:
    $$MaskedCD = (r^e*H(cycleEnd, nonce, claimant)) \bmod n$$
    $$H(cycleEnd, nonce, claimant) = uint128(sha256(abi.encodePacked(cycleEnd, nonce, claimant)))$$
    where,
    - <u>cycleEnd</u>: the block number of the request phase deadline of the current cycle.
    - <u>nonce</u>: random uint256 bit number chosen by depositor. Alows for the creation of unique hashes even when multiple depositors in a cycle have the same intended receipient.
    - <u>claimant</u>: 20 byte address of the intended recepient of the deposit. Ensures that the receipient of the CD is immuatble, irrespective of who submits the SignedCD later.
    - <u>abi.encodePacked(x,y,z)</u>: function that concatenates the bits of xyz, without any padding
    - <u>sha256(x)</u>: hashing function that returns a 256-bit hash of x
    - <u>uint128(x)</u>: takes right-most 128-bits of x and stores it as a 128-bit uint.
    - <u>r</u>: random uint128 bit number chosen by the depositor and known only to the depositor.
    - <u>e</u>: public key exponent for the cycle. Can viewed by calling `getBankerPK()`.
    - <u>n</u>: public key modulus for the cycle. Can viewed by calling `getBankerPK()`.
2. The Cycle Banker can sign a Masked CD on their own systems and submit it to the contract by calling `signMaskedCD(maskedCD, signedMaskedCD)`. A banker can sign a masked CD using the following function:
    $$SignedMaskedCD = (MaskedCD)^d \bmod n$$
    where,
    - <u>n</u>: public key modulus for the cycle (banker's pk at the time of designaation as Cycle Banker)
    - <u>d</u>: private key exponent for the cycle (known only to Cycle Banker)
3. The signature is verified using the previously submitted public exponent to ensure that the MaskedCD was indeed signed by the Cycle Banker.
4. The protocol also ensures that the banker hasn't already signed the same MaskedCD. 
5. If all conditions are met, then the signingFee is transfered to the banker's account balance.
6. A deposit is only recorded once the banker submits the signature. Each cycle has a limit of 50 maximum deposits. Cycle Banker cannot sign more than 50 MaskedCDs in a single cycle. A depositer can call the `transferMoney()` function to refund (1 ether + signingFee) any time before the Cycle Banker signs their Masked CD. However, once a MaskedCD is signed, depositors cannot be the payee in `transferMoney()` until the current cycle ends.


#### <b><u>Request Phase (24 hours)</b></u>
7. If there were no deposits signed in the last phase, then the banker is deregistered (in case deposits were made and they did not sign) and depositors are eligible to withdraw their deposits. The request phase ends and a new cycle starts immediately. This is can be realised by a any participant calling `resetCycle()`.
7. If there were deposits sign then, Depositors can multiply their SignedMaskedCD by $r^{-1} \bmod n$ to get the SignedCD:
    $$SignedMaskedCD = (r^e*H(cycleEnd, nonce, claimant))^d \bmod n$$
    $$SignedMaskedCD = (r^{ed}*H(cycleEnd, nonce, claimant)^d) \bmod n$$
    $$SignedMaskedCD = (r*H(cycleEnd, nonce, claimant)^d) \bmod n$$
    $$SignedCD = (r^{-1}*r*H(cycleEnd, nonce, claimant)^d) \bmod n$$
    $$SignedCD = H(cycleEnd, nonce, claimant)^d \bmod n$$
8. Depositors can share the SignedCD and Nonce with their claimant. If their claimant does not have any ether, they can share both values to an anonymous public forum, where any Intermediary can use those values to make a withdrawal request on the claimant's behalf.
9. The claimant/intermediary can call `requestWithdrawal(signedCD, nonce, claimant)` to request a withdrawal on the claimant's behalf.
10. The function calculates $H(cycleEnd, nonce, claimant)$ using the submitted nonce and claimant. It then verifies that SignedCD is indeed $H(cycleEnd, nonce, claimant)^d$ using the cycle's public key.
11. The function also confirms that this CD hasn't already been claimed in this cycle to prevent double spending.
12. If all the conditions are satisfied then the address of the claimant and intermediary (msg.sender) are recorded.
13. If, at any time during the cycle, the valid CDs claimed is greater than the number of SignedMaskedCDs issued during the cycle, then it is assumed that the banker cheated by manufacturing and signing fake CDs. If that happens:
    1. The banker is blacklisted. Their deposit and account balance are distributed amongst depositors.
    2. The cycle is reset and a new cycle with a new banker begins immediately.
    3. Fees and Claims are not depsoited to their respective Claimants and Intermediaries. Instead, Depositors can now refund their 1 ether deposits.
14. If the number valid CDs claimed <= the number of deposits by the end of the Request Deadline, then we assume that the banker did not cheat and the cycle is can be reset by calling `resetCycle()`. ClaimFees are deposited to intermediary account balances and (1 ether - claimFees) is depsoited to every claimant. Unclaimed deposits cannot be accessed again.
15. All Participants (not participating in the new cycle) can call `transferMoney(payee)` to transfer their account balances to their wallets. New claimants with no funds can request intermediries to call the function on their behalf. Intermediaries receive a transferFee from the payee's account.
17. The Cycle Banker should call `updateKey()` at least once during the cycle. This would not affect the rest of the protocol since the Cycle Banker's Public Key at the time of cycle reset is stored seperately.

## Decentralized Mixer
All members of the blockchain have the exact same privileges. All members can, by default, play the role of Depositors, Claimants and Intermediaries. Furthermore, anyone can become a banker by submitting a refundable security deposit and gets eventually gets the chance to execute the roles of a banker during a cycle.

## Usable by Claimants with 0 ether
Since a Certificate Deposit encodes information regarding its intended Claimant, any intermediary can request withdrawal using a CD on the claimant's behalf without being able to steal their money. Intermediaries receive a claimFee for requesting withdrawals on a claimant's behalf and transferFee for transfering into a claimaint's account on their behalf.

## Security Features (Rational Adversaries)
|Method for Cheating   |Avoided/Detected   |How is it Avoided/Detected
|---|---|---|
|Cycle Banker signs more CDs than were deposited (with himself or his friends as claimants). Thus, stealing Depositor's deposits.|Detected|We know that whenevr the number of valid claims exceeds the number of deposits, the banker must have cheated somehow (since only they can create valid CDs using their private key). By doing a two-phased implementation, we can accuractely track the number of valid deposits signed by the Cycle Banker in the Deposit Phase, and the number of valid CDs claimed during the Request Phase. If claims > signed deposits, then we blacklist the banker, distribute their banker deposit and any account balance amongst depositors, as well as refund the original 1 ether deposits to Depositors. Thus, a rational banker will be disincentivized to cheat. Even if the number of valid CDs claimed is less than the number of signed deposits, the banker will be worried that someone might actually request a claim at the last minute, and thus, would not take the risk.
|Case: block.number = cycle.requestDeadline - 1. The number of valid claims is 1 less than the number of signed deposits. There is only one block left where claimants can request withdrawals. The Cycle Banker can cheat and submit a forged CD and offer to pay the miner of the deadline block such that only the banker's `requestWithdrawal()` transaction is added to the final block, and no other transactions for requestWithdrawal are added to the block. Thus, the banker can get away with cheating because at the end of the deadline, num_claims = num_deposits.| Avoided| The banker cannot guarantee a miner payment because they won't actually receive the money within the same block. The money will actually be received in another block where the banker calls `transferMoney()`, which might be mined by another miner. Regardless, claimants are encouraged to make their claims as early as possible.
| Depositors have an incentive to blame the banker as a cheater since they get their deposit. Thus, they can get the banker to sign their Masked CD in one cycle and only actually claim that CD in another cycle when the banker is Cycle Banker again. Thus, the banker would get labelled as a cheater in the latter cycle (they can make another token deposit in this cycle to be eligible to receive the banker's deposit)| Avoided|This attack is not possible if the banker keeps updating their keys, such that they are using different keys for each cycle where they are the Cycle Banker. Bankers can call `updatekey()` anytime, including when they are Cycle Bankers. This would not affect the rest of the protocol since the Cycle Banker's Public Key at the time of cycle reset is stored seperately. If the banker does not do this, they are putting themselves at risk. Even if the banker does not change their keys, this attack is very difficult for an attacker to execute since that would require them to predict the exact deadline of the next cycle when that banker will become Cycle Banker again. Since bankers are shuffled with every de-registration or blacklist event and since cycle's can end early, this is very unpredictable.
|Same Signed CD is claimed twice| Avoided| Protocol keeps a track of all SignedCDs used to request withdrawal in that cycle.
|Cycle Banker does not sign some deposits| Detected| Depositors with unsigned MaskedCDs are eligible to refund 1 ether + signingFee anytime by calling `transferMoney()`
| Cycle Banker Does not sign any deposits, willfully or because they are out-of-business| Detected| The banker is de-registered and their bankers deposit is added back to their account balance. Depositors can claim a refund. If there no actual deposits in that cycle, and the banker was indeed legitimate, then can register as banker again.
| Re-entrency during payment in `transferMoney()`| Avoided| All contract states are changed before fallback function is called.
| Functions consume so much gas that they cannot be called.| Avoided| All functions have a constant maximum amount of gas usage. All functions, except `_resetCycle()` and `bankerCheated()`, are O(1). Furthermore, the loops in `_resetCycle()` and `bankerCheated()` cannot iterate more time times than the number of depositors in that cycle, which is capped at 50 maxDeposits.

## Malicious Adverseries
This contract is not fully equipped to deal with irrational malicious adversaries. Thus, it is prone to malicious Denial-of-Service attacks. For example:
- A malicious person can make several accounts and register with a banker using all of them. Then they can just not sign any MaskedCD. However, this is not rationale since they only lose gas and gain nothing.
- Malicious claimants can have fallback functions that consume infinite amounts of gas. Even though the transaction will be reverted in this case and claimants wouldnt gain anything, intermediaries still stand to lose all that gas for nothing.

There may be more Malicious Attacks that are not addressed in this contract.


