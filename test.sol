// SPDX-License-Identifier: GPL-3.0

pragma solidity >=0.8.0 <0.9.0;

contract Test {
    function mod_exp(uint256 base, uint256 exp, uint256 n) public pure returns (uint){
        uint a = 1;

        while (exp > 0){
            if ((exp & 1) > 0) a = (a * base) % n;
            exp >>= 1;
            base = (base**2) % n;
        }
        return a;
    }

    function createMaskedCD(uint nonce, address claimant, uint128 banker_pk, uint128 n, uint128 r) public pure returns (uint128){
        uint128 hash = uint128(uint256(sha256(abi.encodePacked(nonce, claimant))));
        uint128 encrypted_r = uint128(mod_exp(uint(r), uint(banker_pk), uint(n)));
        return uint128((uint(hash) * uint(encrypted_r)) % n);
    }

    function signMaskedCD(uint128 maskedCD, uint128 priv, uint128 n) public pure returns (uint128){
        return uint128(mod_exp(uint(maskedCD), uint(priv), uint(n)));
    }

    function generate_hash(uint nonce, address claimant, uint128 n) public pure returns (uint128){
            return uint128(uint256(sha256(abi.encodePacked(nonce, claimant)))) % n;
        }
}