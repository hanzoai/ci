// Command ci runs the fleet dashboard as its own server.
//
// The surface itself lives in the package, not here, so it can be MOUNTED as
// well as run — hanzoai/cloud carries /v1/deploy behind the gateway's IAM
// identity, and this is the CI half of that same delivery plane. A package main
// cannot be imported by anything, which is why this surface was the one a valid
// hanzo.id token could not read.
package main

import ci "hanzo.ai/ci"

func main() { ci.Main() }
