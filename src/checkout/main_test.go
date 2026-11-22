// Copyright The OpenTelemetry Authors
// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"log/slog"
	"net"
	"testing"
	"time"

	"github.com/IBM/sarama"
	"github.com/IBM/sarama/mocks"
	"go.opentelemetry.io/otel/attribute"
	otelcodes "go.opentelemetry.io/otel/codes"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/sdk/trace/tracetest"

	pb "github.com/open-telemetry/opentelemetry-demo/src/checkout/genproto/oteldemo"
	"github.com/open-telemetry/opentelemetry-demo/src/checkout/kafka"
)

// recordSpans sets the globals that main() would, and returns what records the spans.
func recordSpans(t *testing.T) *tracetest.SpanRecorder {
	t.Helper()
	recorder := tracetest.NewSpanRecorder()
	logger = slog.New(slog.DiscardHandler)
	tracer = sdktrace.NewTracerProvider(sdktrace.WithSpanProcessor(recorder)).Tracer("checkout")
	return recorder
}

func producerSuccess(t *testing.T, span sdktrace.ReadOnlySpan) bool {
	t.Helper()
	for _, kv := range span.Attributes() {
		if kv.Key == attribute.Key("messaging.kafka.producer.success") {
			return kv.Value.AsBool()
		}
	}
	t.Fatal("the span has no messaging.kafka.producer.success attribute")
	return false
}

// Kafka wasn't ready when the service started, so there is no producer. This used to panic.
func TestSendToPostProcessorWithoutProducer(t *testing.T) {
	recorder := recordSpans(t)
	cs := &checkout{kafkaBrokerSvcAddr: "kafka:9092"}

	cs.sendToPostProcessor(context.Background(), &pb.OrderResult{OrderId: "order-1"})

	spans := recorder.Ended()
	if len(spans) != 1 {
		t.Fatalf("got %d spans, want 1", len(spans))
	}
	if got := spans[0].Status().Code; got != otelcodes.Error {
		t.Errorf("span status is %v, want Error: a dropped message has to show up in the trace", got)
	}
	if producerSuccess(t, spans[0]) {
		t.Error("the span says that the message was produced")
	}
}

func TestSendToPostProcessorWithProducer(t *testing.T) {
	recorder := recordSpans(t)
	config := mocks.NewTestConfig()
	config.Producer.Return.Successes = true
	producer := mocks.NewAsyncProducer(t, config)
	producer.ExpectInputAndSucceed()
	cs := &checkout{kafkaBrokerSvcAddr: "kafka:9092", KafkaProducerClient: producer}

	cs.sendToPostProcessor(context.Background(), &pb.OrderResult{OrderId: "order-1"})

	if err := producer.Close(); err != nil { // also fails the test if the expected message never came
		t.Error(err)
	}
	spans := recorder.Ended()
	if len(spans) != 1 {
		t.Fatalf("got %d spans, want 1", len(spans))
	}
	if !producerSuccess(t, spans[0]) {
		t.Error("the span says that the message was not produced")
	}
}

// The broker comes up after the service has started to look for it.
func TestConnectToKafkaKeepsTrying(t *testing.T) {
	recordSpans(t)
	// Reserve an address, and leave it with nothing listening.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := listener.Addr().String()
	listener.Close()

	// As main() does: one attempt before it serves, and the rest in the background.
	if _, err := kafka.CreateKafkaProducer([]string{addr}, logger); err == nil {
		t.Fatal("created a producer, though no broker is listening")
	}
	cs := &checkout{kafkaBrokerSvcAddr: addr}
	go cs.connectToKafka()

	// Long enough for the first attempt in the background, which starts after a second, to have failed.
	time.Sleep(2500 * time.Millisecond)
	if cs.kafkaProducer() != nil {
		t.Fatal("there is a producer, though no broker is listening")
	}

	broker := sarama.NewMockBrokerAddr(t, 1, addr)
	defer broker.Close()
	broker.SetHandlerByMap(map[string]sarama.MockResponse{
		"ApiVersionsRequest": sarama.NewMockApiVersionsResponse(t),
		"MetadataRequest":    sarama.NewMockMetadataResponse(t).SetBroker(addr, broker.BrokerID()),
	})

	deadline := time.Now().Add(20 * time.Second)
	for cs.kafkaProducer() == nil {
		if time.Now().After(deadline) {
			t.Fatal("no producer 20 seconds after the broker came up")
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err := cs.kafkaProducer().Close(); err != nil {
		t.Error(err)
	}
}
