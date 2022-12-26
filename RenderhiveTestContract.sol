// SPDX-License-Identifier: MIT
// 2022 © Christian Stolze
// For testing purposes only!

pragma solidity >=0.7.0 <=0.8.9;
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/security/ReentrancyGuard.sol";
import "https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/math/SafeMath.sol";


// Renderhive Smart Contract
contract RenderhiveTestContract is ReentrancyGuard {
  using SafeMath for uint;

  // structure to store user information
  struct User {

      uint userId;
      string username;
      uint registrationTime;
      bool isRegistered;

  }

  // mapping to store user information
  mapping(address => User) internal users;

  // mapping to store whether a username is in use
  mapping(string => bool) internal usernames;

  // next user ID to be assigned
  uint internal nextUserId;

  // events
  event RegisteredUser(uint userId, string username, address wallet, uint registrationTime);
  event DeletedUser(uint userId, string username, address wallet, uint deletionTime);

  // initialize the users mapping with a default value for any keys that are not explicitly set
  constructor() {

      // initialize nextUserId
      nextUserId = 0;

  }

  // function to register a new user
  function register(string memory username) public nonReentrant {

      // check if the user is already registered
      require(!users[msg.sender].isRegistered, "User already registered");

      // check if the username is already in use
      require(!usernames[username], "Username already in use");

      // create a new user
      User memory user = User({
          userId: nextUserId.add(1),
          username: username,
          registrationTime: block.timestamp,
          isRegistered: true
      });

      // add the user to the mapping
      users[msg.sender] = user;

      // mark the username as in use
      usernames[username] = true;

      // emit event
      emit RegisteredUser(users[msg.sender].userId, users[msg.sender].username, msg.sender, users[msg.sender].registrationTime);

  }

  // function to unregister the account
  function unregister() public nonReentrant {

      // check if the user is registered
      require(users[msg.sender].isRegistered, "User not registered");

      // delete the user from the mapping
      delete users[msg.sender];

      // mark the username as not in use
      delete usernames[users[msg.sender].username];

      // emit event
      emit DeletedUser(users[msg.sender].userId, users[msg.sender].username, msg.sender, block.timestamp);

  }

}
