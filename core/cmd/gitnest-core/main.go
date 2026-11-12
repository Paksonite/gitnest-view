// gitnest-core is the engine of GitNest View: it finds repositories and runs
// git for the macOS app, which starts it and talks to it over stdin/stdout
// (see internal/rpc). It has no interface of its own.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/Paksonite/gitnest-view/core/internal/rpc"
)

// Set at build time with -ldflags "-X main.version=...".
var version = "dev"

func main() {
	if len(os.Args) > 1 {
		switch os.Args[1] {
		case "--version", "version":
			fmt.Println(version)
			return
		default:
			fmt.Fprintln(os.Stderr, "gitnest-core is started by GitNest View and takes no arguments (except --version)")
			os.Exit(2)
		}
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	srv := rpc.NewServer()
	register(srv)
	// Serve returns when the app closes our stdin: that is how it stops us,
	// and how we notice the app is gone.
	if err := srv.Serve(ctx, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "gitnest-core:", err)
		os.Exit(1)
	}
}
