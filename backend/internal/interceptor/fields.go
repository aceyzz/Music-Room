package interceptor

import (
	"fmt"

	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
)

// This file reads and writes request fields by name, through protoreflect.
//
// Reflection rather than a generated accessor per method because the
// alternative is the same eight lines copied into every one of the 34 handlers,
// which is how a permission check ends up missing from the thirty-fifth. The
// names it looks up are not free-form: TestPolicyFieldsExistOnEveryRequest
// resolves every one of them against the real message descriptors, so a typo or
// a renamed proto field fails the build rather than a request.
//
// Writing to the request the handler is about to receive is the point, not a
// side effect. The interceptor resolves the public UUID it just checked into the
// internal id and puts it there, so the handler cannot act on a different object
// than the one that was authorized -- it has no other id to act on.

func requestMessage(req any) (protoreflect.Message, error) {
	message, ok := req.(proto.Message)
	if !ok {
		return nil, fmt.Errorf("request of type %T is not a proto message", req)
	}
	return message.ProtoReflect(), nil
}

func field(message protoreflect.Message, name string) (protoreflect.FieldDescriptor, error) {
	descriptor := message.Descriptor().Fields().ByName(protoreflect.Name(name))
	if descriptor == nil {
		return nil, fmt.Errorf("%s has no field %q", message.Descriptor().FullName(), name)
	}
	return descriptor, nil
}

func stringField(message protoreflect.Message, name string) (string, error) {
	descriptor, err := field(message, name)
	if err != nil {
		return "", err
	}
	if descriptor.Kind() != protoreflect.StringKind {
		return "", fmt.Errorf("%s.%s is %s, want string", message.Descriptor().FullName(), name, descriptor.Kind())
	}
	return message.Get(descriptor).String(), nil
}

func setStringField(message protoreflect.Message, name, value string) error {
	descriptor, err := field(message, name)
	if err != nil {
		return err
	}
	if descriptor.Kind() != protoreflect.StringKind {
		return fmt.Errorf("%s.%s is %s, want string", message.Descriptor().FullName(), name, descriptor.Kind())
	}
	message.Set(descriptor, protoreflect.ValueOfString(value))
	return nil
}

// int64Field reads back a field this package itself stamped (StampField) --
// used by activity logging to recover which object a Requirement resolved,
// after the fact, without threading extra return values through enforce.
func int64Field(message protoreflect.Message, name string) (int64, error) {
	descriptor, err := field(message, name)
	if err != nil {
		return 0, err
	}
	if descriptor.Kind() != protoreflect.Int64Kind {
		return 0, fmt.Errorf("%s.%s is %s, want int64", message.Descriptor().FullName(), name, descriptor.Kind())
	}
	return message.Get(descriptor).Int(), nil
}

func setInt64Field(message protoreflect.Message, name string, value int64) error {
	descriptor, err := field(message, name)
	if err != nil {
		return err
	}
	if descriptor.Kind() != protoreflect.Int64Kind {
		return fmt.Errorf("%s.%s is %s, want int64", message.Descriptor().FullName(), name, descriptor.Kind())
	}
	message.Set(descriptor, protoreflect.ValueOfInt64(value))
	return nil
}
