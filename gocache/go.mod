module hanzo.ai/ci/gocache

// Its own module, at the oldest Go that speaks GOCACHEPROG, so the job builds
// it with whatever toolchain the caller's go.mod provisioned and never fetches
// another one. Standard library only.
go 1.24
