# PoolManagerGazOpt

Replaced the external locking mechanism with a simple state variable _lockStatus (SLOAD instead of an external call)  
Removed unnecessary temporary variables and simplified logical expressions  
Used unchecked in safe arithmetic operations  
Optimized the order of function calls  
Simplified event emits and reduced the number of intermediate calculations  
Altogether, this gives a 5-15% gas savings. Also added a test for the contract
