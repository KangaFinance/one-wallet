# Harmony TOTP Smart Contract 

## Webclient

Check out demo at [https://hashmesan.github.io/harmony-totp/webclient/dist](https://hashmesan.github.io/harmony-totp/webclient/dist). 
Compatible with Ethereum networks & Harmony on Metamask.

## Build smart contract

```
yarn
truffle build
```

## Setup WebClient

```
yarn (at the base level)
cd webclient
yarn
yarn dev
```

Visit http://localhost:8082

## Wallet Design

TOTP/Google Authenticator Unlocks wallet for:
* Payment within the daily limit
* Add / remove guardians
* Drain account back address given at constructor

There are limited number of tokens available on the wallet. Call getRemainingTokens() to check. 

When TOTP/Google Authenticator Tokens depleted:
* Drain account can request drain back
* replenishMoreTokens() to add more tokens

If you lose the Google Authenticator token, you can initiate recovery token via your guardians.
* Requires Ceil(N/2) 

## TODO 

- [ ] Change duration/depth does the work in webworker, and show progress wheel.
- [ ] Update TOTP code show some progress / background since takes a while.
- [ ] Investigate into IndexDB for larger storage. Current implementation will break at large depth with hashes greater than 5MB or 10MB depending on browser.
- [ ] 2 TOTP code hashed together to generate stronger hashes.
- [ ] Drain account function after all codes are expired.
- [ ] Environment selector or indicator ?

## Credits

* Research paper: Ivan Homoliak & et al. https://arxiv.org/pdf/1812.03598.pdf
* https://github.com/ivan-homoliak-sutd/SmartOTPs