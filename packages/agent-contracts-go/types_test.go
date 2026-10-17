package agentcontracts

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/yaml"
)

// Every manifest under examples/ decodes into these types with unknown fields
// disallowed, so a field the CRDs accept but the Go types miss fails here.
func TestEveryExampleManifestDecodesStrictly(t *testing.T) {
	scheme := runtime.NewScheme()
	if err := AddToScheme(scheme); err != nil {
		t.Fatalf("AddToScheme: %v", err)
	}
	files, err := filepath.Glob("../../examples/*.yaml")
	if err != nil || len(files) == 0 {
		t.Fatalf("no examples found: %v", err)
	}
	decoded := 0
	for _, file := range files {
		content, err := os.ReadFile(file)
		if err != nil {
			t.Fatalf("read %s: %v", file, err)
		}
		for _, document := range strings.Split(string(content), "\n---") {
			decoded += decodeStrictly(t, scheme, file, document)
		}
	}
	if decoded == 0 {
		t.Fatal("decoded no resources")
	}
}

func decodeStrictly(t *testing.T, scheme *runtime.Scheme, file, document string) int {
	t.Helper()
	asJSON, err := yaml.YAMLToJSON([]byte(document))
	if err != nil {
		t.Fatalf("%s: %v", file, err)
	}
	var header struct{ Kind string }
	if err := json.Unmarshal(asJSON, &header); err != nil || header.Kind == "" {
		return 0
	}
	object, err := scheme.New(SchemeGroupVersion.WithKind(header.Kind))
	if err != nil {
		t.Fatalf("%s: kind %s is not registered: %v", file, header.Kind, err)
	}
	decoder := json.NewDecoder(bytes.NewReader(asJSON))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(object); err != nil {
		t.Fatalf("%s: %s does not decode strictly: %v", file, header.Kind, err)
	}
	return 1
}

func TestDeepCopyLeavesTheOriginalUntouched(t *testing.T) {
	original := &Agent{Spec: AgentSpec{StationRef: "story-writer", Parameters: map[string]string{"title": "first"}}}

	copied := original.DeepCopy()
	copied.Spec.Parameters["title"] = "second"

	if original.Spec.Parameters["title"] != "first" {
		t.Fatalf("original parameters changed to %q", original.Spec.Parameters["title"])
	}
}
