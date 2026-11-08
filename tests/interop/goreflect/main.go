// grpc-go's reflection client against the reflection service of nimgrpc: lists the services,
// then asks for a symbol and builds the descriptors it gets, which fails if an import is missing.
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"sort"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	v1 "google.golang.org/grpc/reflection/grpc_reflection_v1"
	v1alpha "google.golang.org/grpc/reflection/grpc_reflection_v1alpha"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protodesc"
	"google.golang.org/protobuf/types/descriptorpb"
)

var failed bool

func check(name string, ok bool, detail string) {
	if ok {
		fmt.Println("ok  ", name, detail)
	} else {
		fmt.Println("FAIL", name, detail)
		failed = true
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:50051", "server address")
	flag.Parse()
	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Println("FAIL dial:", err)
		os.Exit(1)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	stream, err := v1.NewServerReflectionClient(conn).ServerReflectionInfo(ctx)
	if err != nil {
		fmt.Println("FAIL v1 stream:", err)
		os.Exit(1)
	}
	send := func(req *v1.ServerReflectionRequest) *v1.ServerReflectionResponse {
		if err := stream.Send(req); err != nil {
			fmt.Println("FAIL send:", err)
			os.Exit(1)
		}
		resp, err := stream.Recv()
		if err != nil {
			fmt.Println("FAIL recv:", err)
			os.Exit(1)
		}
		return resp
	}

	// list_services
	resp := send(&v1.ServerReflectionRequest{Host: "h", MessageRequest: &v1.ServerReflectionRequest_ListServices{ListServices: "*"}})
	var names []string
	for _, s := range resp.GetListServicesResponse().GetService() {
		names = append(names, s.Name)
	}
	sort.Strings(names)
	check("v1 list_services", len(names) == 3 && names[2] == "reflect.test.Echo", fmt.Sprint(names))
	check("valid_host and original_request come back", resp.ValidHost == "h" && resp.OriginalRequest.GetListServices() == "*", resp.ValidHost)

	// file_containing_symbol, and every file it brings must resolve
	resp = send(&v1.ServerReflectionRequest{MessageRequest: &v1.ServerReflectionRequest_FileContainingSymbol{FileContainingSymbol: "reflect.test.Echo"}})
	set := &descriptorpb.FileDescriptorSet{}
	for _, raw := range resp.GetFileDescriptorResponse().GetFileDescriptorProto() {
		fd := &descriptorpb.FileDescriptorProto{}
		if err := proto.Unmarshal(raw, fd); err != nil {
			check("unmarshal a file", false, err.Error())
			continue
		}
		set.File = append(set.File, fd)
	}
	files, err := protodesc.NewFiles(set)
	check("the files build (imports present)", err == nil && len(set.File) == 2, fmt.Sprint(len(set.File), " files ", err))
	if err == nil {
		d, err := files.FindDescriptorByName("reflect.test.Echo")
		check("the service is found by name", err == nil && string(d.FullName()) == "reflect.test.Echo", fmt.Sprint(d, err))
		var chat *descriptorpb.MethodDescriptorProto
		for _, s := range set.File[0].Service {
			for _, m := range s.Method {
				if m.GetName() == "Chat" {
					chat = m
				}
			}
		}
		check("Chat is bidirectional streaming", chat != nil && chat.GetClientStreaming() && chat.GetServerStreaming(), fmt.Sprint(chat))
		m, err := files.FindDescriptorByName("reflect.test.EchoRequest.Tag")
		check("a nested message resolves", err == nil && m != nil, fmt.Sprint(m, err))
	}

	// an unknown symbol
	resp = send(&v1.ServerReflectionRequest{MessageRequest: &v1.ServerReflectionRequest_FileContainingSymbol{FileContainingSymbol: "reflect.test.Nobody"}})
	check("an unknown symbol is an error response with NOT_FOUND", resp.GetErrorResponse().GetErrorCode() == 5, fmt.Sprint(resp.GetErrorResponse()))

	// v1alpha, the one older tools speak
	a, err := v1alpha.NewServerReflectionClient(conn).ServerReflectionInfo(ctx)
	if err != nil {
		check("v1alpha stream", false, err.Error())
	} else {
		a.Send(&v1alpha.ServerReflectionRequest{MessageRequest: &v1alpha.ServerReflectionRequest_ListServices{ListServices: "*"}})
		ar, err := a.Recv()
		check("v1alpha list_services", err == nil && len(ar.GetListServicesResponse().GetService()) == 3, fmt.Sprint(err))
	}
	stream.CloseSend()
	if failed {
		os.Exit(1)
	}
	fmt.Println("ALL OK")
}
