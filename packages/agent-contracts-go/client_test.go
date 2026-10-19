package agentcontracts

import (
	"context"
	"testing"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/fake"
)

func newFakeClient(t *testing.T, objects ...client.Object) *Client {
	t.Helper()
	scheme := runtime.NewScheme()
	if err := AddToScheme(scheme); err != nil {
		t.Fatalf("AddToScheme: %v", err)
	}
	kube := fake.NewClientBuilder().WithScheme(scheme).WithObjects(objects...).Build()
	return NewClient(kube, "")
}

func agentNamed(name string, phase Phase, labels map[string]string) *Agent {
	return &Agent{
		ObjectMeta: metav1.ObjectMeta{Name: name, Namespace: DefaultNamespace, Labels: labels},
		Spec:       AgentSpec{StationRef: "story-writer"},
		Status:     AgentStatus{Phase: phase},
	}
}

func TestCreateAgentPutsTheRunInTheClientNamespace(t *testing.T) {
	agents := newFakeClient(t)
	ctx := context.Background()

	if err := agents.CreateAgent(ctx, &Agent{ObjectMeta: metav1.ObjectMeta{Name: "run-1"}, Spec: AgentSpec{StationRef: "story-writer"}}); err != nil {
		t.Fatalf("CreateAgent: %v", err)
	}
	created, err := agents.GetAgent(ctx, "run-1")
	if err != nil {
		t.Fatalf("GetAgent: %v", err)
	}
	if created.Namespace != DefaultNamespace || created.Spec.StationRef != "story-writer" {
		t.Fatalf("got namespace %q stationRef %q, want %q story-writer", created.Namespace, created.Spec.StationRef, DefaultNamespace)
	}
}

func TestFindAgentsReturnsOnlyTheRunsMatchingTheSelector(t *testing.T) {
	agents := newFakeClient(t,
		agentNamed("web-1", PhaseRunning, map[string]string{"team": "web"}),
		agentNamed("data-1", PhaseRunning, map[string]string{"team": "data"}))

	found, err := agents.FindAgents(context.Background(), "team=web")
	if err != nil {
		t.Fatalf("FindAgents: %v", err)
	}
	if len(found) != 1 || found[0].Name != "web-1" {
		t.Fatalf("got %d agents (%v), want only web-1", len(found), found)
	}
}

func TestFindAgentsRejectsAnInvalidSelector(t *testing.T) {
	if _, err := newFakeClient(t).FindAgents(context.Background(), "team in (web"); err == nil {
		t.Fatal("want an error for an unparsable selector")
	}
}

func TestGetModelCatalogReadsTheDefaultCatalog(t *testing.T) {
	catalog := &ModelCatalog{
		ObjectMeta: metav1.ObjectMeta{Name: "default", Namespace: DefaultNamespace},
		Status:     ModelCatalogStatus{Vendors: []VendorModels{{Vendor: "claude", Models: []ModelInfo{{ID: "claude-opus-5-5"}}}}},
	}

	got, err := newFakeClient(t, catalog).GetModelCatalog(context.Background())
	if err != nil {
		t.Fatalf("GetModelCatalog: %v", err)
	}
	if got.Status.Vendors[0].Models[0].ID != "claude-opus-5-5" {
		t.Fatalf("got %+v, want claude-opus-5-5", got.Status)
	}
}

func TestApplyStationStoresTheStationInTheClientNamespace(t *testing.T) {
	agents := newFakeClient(t)
	ctx := context.Background()
	station := &Station{ObjectMeta: metav1.ObjectMeta{Name: "story-writer"}, Spec: StationSpec{AgentDefRef: "story-writer"}}

	if err := agents.ApplyStation(ctx, station); err != nil {
		t.Fatalf("ApplyStation: %v", err)
	}
	stored := &Station{}
	if err := agents.kube.Get(ctx, client.ObjectKey{Namespace: DefaultNamespace, Name: "story-writer"}, stored); err != nil {
		t.Fatalf("Get: %v", err)
	}
	if stored.Spec.AgentDefRef != "story-writer" {
		t.Fatalf("got agentDefRef %q, want story-writer", stored.Spec.AgentDefRef)
	}
}

func TestApplyStationWithoutANameFails(t *testing.T) {
	err := newFakeClient(t).ApplyStation(context.Background(), &Station{})
	if err == nil || err.Error() != "apply Station: metadata.name is required" {
		t.Fatalf("got %v, want the missing-name error", err)
	}
}

func TestWaitForAgentReturnsTheRunOnceSucceeded(t *testing.T) {
	agents := newFakeClient(t, agentNamed("run-1", PhaseSucceeded, nil))

	finished, err := agents.WaitForAgent(context.Background(), "run-1", time.Millisecond)
	if err != nil || finished.Status.Phase != PhaseSucceeded {
		t.Fatalf("got %v, %v; want the Succeeded run", finished, err)
	}
}

func TestWaitForAgentStopsWhenTheContextEnds(t *testing.T) {
	agents := newFakeClient(t, agentNamed("run-1", PhaseRunning, nil))
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()

	if _, err := agents.WaitForAgent(ctx, "run-1", time.Millisecond); err == nil {
		t.Fatal("want an error once the context ends before the run finishes")
	}
}

func TestIsTerminalIsTrueOnlyForSucceededAndFailed(t *testing.T) {
	got := []bool{}
	for _, phase := range []Phase{PhasePending, PhaseRunning, PhaseSucceeded, PhaseFailed} {
		got = append(got, IsTerminal(agentNamed("run", phase, nil)))
	}
	if want := []bool{false, false, true, true}; !equalBools(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func equalBools(left, right []bool) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}
