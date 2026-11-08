// A health-checking client of grpc-go (the official stubs) for the nimgrpc interop test.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
	"google.golang.org/grpc/status"
)

func main() {
	addr := flag.String("addr", "127.0.0.1:50051", "server address")
	flag.Parse()
	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Println("FAIL dial:", err)
		os.Exit(1)
	}
	defer conn.Close()
	c := healthpb.NewHealthClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	fail := false
	check := func(name string, ok bool, detail string) {
		if ok {
			fmt.Println("ok  ", name, detail)
		} else {
			fmt.Println("FAIL", name, detail)
			fail = true
		}
	}
	r, err := c.Check(ctx, &healthpb.HealthCheckRequest{})
	check("Check whole server", err == nil && r.Status == healthpb.HealthCheckResponse_SERVING, fmt.Sprint(r, err))
	r, err = c.Check(ctx, &healthpb.HealthCheckRequest{Service: "a.B"})
	check("Check a.B", err == nil && r.Status == healthpb.HealthCheckResponse_NOT_SERVING, fmt.Sprint(r, err))
	_, err = c.Check(ctx, &healthpb.HealthCheckRequest{Service: "nobody"})
	check("Check unknown is NOT_FOUND", status.Code(err) == codes.NotFound, fmt.Sprint(err))
	l, err := c.List(ctx, &healthpb.HealthListRequest{})
	check("List", err == nil && len(l.Statuses) == 2 &&
		l.Statuses[""].Status == healthpb.HealthCheckResponse_SERVING &&
		l.Statuses["a.B"].Status == healthpb.HealthCheckResponse_NOT_SERVING, fmt.Sprint(l, err))
	w, err := c.Watch(ctx, &healthpb.HealthCheckRequest{Service: "later.C"})
	if err != nil {
		check("Watch", false, err.Error())
	} else {
		m, err := w.Recv()
		check("Watch first is SERVICE_UNKNOWN", err == nil && m.Status == healthpb.HealthCheckResponse_SERVICE_UNKNOWN, fmt.Sprint(m, err))
		// the Nim side sets later.C to SERVING once it sees this line
		fmt.Println("WATCHING")
		m, err = w.Recv()
		check("Watch then SERVING", err == nil && m.Status == healthpb.HealthCheckResponse_SERVING, fmt.Sprint(m, err))
		m, err = w.Recv()
		check("Watch then NOT_SERVING after shutdown", err == nil && m.Status == healthpb.HealthCheckResponse_NOT_SERVING, fmt.Sprint(m, err))
	}
	if fail {
		os.Exit(1)
	}
	fmt.Println("ALL OK")
}
