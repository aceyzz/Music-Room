package interceptor

import (
	"strings"
	"testing"

	// Blank import: the generated package registers its descriptors on init,
	// and that registry is what these tests read. The interceptor itself never
	// imports it -- it works through protoreflect, so it does not need to know
	// a single message type.
	_ "example.com/music-app/gen/go/music_room/v1"
	"example.com/music-app/internal/authz"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/reflect/protoregistry"
)

// The policy table is a hand-written index of the protos, and a hand-written
// index drifts. These two tests are what makes the drift a build failure
// instead of a permission bug: the first catches an RPC nobody protected, the
// second catches a field name that no longer exists.
//
// They read the real descriptors out of the proto registry rather than a list
// kept here, so adding an RPC is enough to make the first one fail.

const servicePackage = "music_room.v1"

// services collects every service declared in the music_room.v1 package.
func services(t *testing.T) []protoreflect.ServiceDescriptor {
	t.Helper()

	var found []protoreflect.ServiceDescriptor
	protoregistry.GlobalFiles.RangeFiles(func(file protoreflect.FileDescriptor) bool {
		if file.Package() != servicePackage {
			return true
		}
		for i := 0; i < file.Services().Len(); i++ {
			found = append(found, file.Services().Get(i))
		}
		return true
	})

	if len(found) == 0 {
		t.Fatalf("no %s service found in the proto registry -- every assertion "+
			"below would be vacuous", servicePackage)
	}
	return found
}

func TestEveryRPCHasAPolicy(t *testing.T) {
	for _, service := range services(t) {
		methods := service.Methods()
		for i := 0; i < methods.Len(); i++ {
			method := methods.Get(i)
			fullMethod := "/" + string(service.FullName()) + "/" + string(method.Name())
			if _, ok := policies[fullMethod]; !ok {
				t.Errorf("%s has no policy entry: it would be DENIED at runtime.\n"+
					"Add it to policies in policy.go -- Public for an RPC that must "+
					"work without a session, an empty Policy{} for one that needs "+
					"nothing but authentication.", fullMethod)
			}
		}
	}
}

// TestNoPolicyForAMethodThatDoesNotExist is the other direction: a policy left
// behind after an RPC was renamed protects nothing, and reads as if it does.
func TestNoPolicyForAMethodThatDoesNotExist(t *testing.T) {
	real := map[string]bool{}
	for _, service := range services(t) {
		methods := service.Methods()
		for i := 0; i < methods.Len(); i++ {
			real["/"+string(service.FullName())+"/"+string(methods.Get(i).Name())] = true
		}
	}

	for fullMethod := range policies {
		if !real[fullMethod] {
			t.Errorf("policies has an entry for %s, which is not an RPC in %s",
				fullMethod, servicePackage)
		}
	}
}

func requestOf(t *testing.T, fullMethod string) protoreflect.MessageDescriptor {
	t.Helper()

	cut := strings.LastIndex(fullMethod, "/")
	serviceName := protoreflect.FullName(strings.TrimPrefix(fullMethod[:cut], "/"))
	methodName := protoreflect.Name(fullMethod[cut+1:])

	descriptor, err := protoregistry.GlobalFiles.FindDescriptorByName(serviceName)
	if err != nil {
		t.Fatalf("service %s: %v", serviceName, err)
	}
	service, ok := descriptor.(protoreflect.ServiceDescriptor)
	if !ok {
		t.Fatalf("%s is not a service", serviceName)
	}
	method := service.Methods().ByName(methodName)
	if method == nil {
		t.Fatalf("%s has no method %s", serviceName, methodName)
	}
	return method.Input()
}

func assertField(t *testing.T, request protoreflect.MessageDescriptor, name string, kind protoreflect.Kind, why string) {
	t.Helper()

	descriptor := request.Fields().ByName(protoreflect.Name(name))
	if descriptor == nil {
		t.Errorf("%s has no field %q (%s)", request.FullName(), name, why)
		return
	}
	if descriptor.Kind() != kind {
		t.Errorf("%s.%s is %s, want %s (%s)", request.FullName(), name, descriptor.Kind(), kind, why)
	}
}

// TestPolicyFieldsExistOnEveryRequest checks every field name the table names,
// including the int64 ones it derives rather than declares.
func TestPolicyFieldsExistOnEveryRequest(t *testing.T) {
	for fullMethod, policy := range policies {
		if policy.Public {
			continue
		}
		request := requestOf(t, fullMethod)

		if policy.CallerPublicIDField != "" {
			assertField(t, request, policy.CallerPublicIDField, protoreflect.StringKind,
				"the caller's public id, compared against the session")
			assertField(t, request, stampFieldFor(policy.CallerPublicIDField), protoreflect.Int64Kind,
				"filled in from the session so the handler cannot be lied to")
		}

		for _, requirement := range policy.Require {
			assertField(t, request, requirement.IDField, protoreflect.StringKind,
				"the object this requirement is about")
			if requirement.Resolve {
				assertField(t, request, requirement.StampField(), protoreflect.Int64Kind,
					"filled in with the resolved internal id")
			}
		}
	}
}

func TestStampFieldDerivation(t *testing.T) {
	for _, testCase := range []struct{ publicField, want string }{
		{"public_id", "id"},
		{"playlist_public_id", "playlist_id"},
		{"invitee_user_public_id", "invitee_user_id"},
		{"source_playlist_public_id", "source_playlist_id"},
		{"blocked_public_id", "blocked_id"},
	} {
		if got := stampFieldFor(testCase.publicField); got != testCase.want {
			t.Errorf("stampFieldFor(%q) = %q, want %q", testCase.publicField, got, testCase.want)
		}
	}
}

// TestReadPermissionsDenyAsNotFound pins the rule from docs/permissions.md §10:
// discovery and read are the same permission, so a resource you cannot view
// must be indistinguishable from one that does not exist. A PermissionDenied on
// a read confirms the resource exists, which is the disclosure the private
// visibility setting was supposed to prevent.
func TestReadPermissionsDenyAsNotFound(t *testing.T) {
	// Built at runtime rather than as a map literal: can_view is one string
	// shared by playlist, event and device, so the constants collide as keys.
	readPermissions := map[authz.Permission]bool{}
	for _, permission := range []authz.Permission{
		authz.PermPlaylistView, authz.PermEventView, authz.PermDeviceView,
		authz.PermUserViewProfile,
	} {
		readPermissions[permission] = true
	}

	for fullMethod, policy := range policies {
		for _, requirement := range policy.Require {
			if readPermissions[requirement.Permission] && !requirement.NotFound {
				t.Errorf("%s checks %s but denies with PermissionDenied, which tells "+
					"the caller the object exists", fullMethod, requirement.Permission)
			}
		}
	}
}
