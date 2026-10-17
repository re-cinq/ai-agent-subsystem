package agentcontracts

import (
	"context"
	"fmt"
	"time"

	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// DefaultNamespace is the namespace the subsystem installs into and runs Agents in.
const DefaultNamespace = "ai-agents"

const fieldManager = "agent-contracts"

const modelCatalogName = "default"

// Client creates and reads the subsystem's resources in one namespace through a
// controller-runtime client whose scheme includes this package (see AddToScheme).
type Client struct {
	kube client.Client

	namespace string
}

// NewClient returns a Client for namespace, or DefaultNamespace when namespace is "".
func NewClient(kube client.Client, namespace string) *Client {
	if namespace == "" {
		namespace = DefaultNamespace
	}
	return &Client{kube: kube, namespace: namespace}
}

// CreateAgent starts one run. agent.Namespace is set to the client's namespace.
func (c *Client) CreateAgent(ctx context.Context, agent *Agent) error {
	agent.Namespace = c.namespace
	return c.kube.Create(ctx, agent)
}

// GetAgent reads one Agent by name.
func (c *Client) GetAgent(ctx context.Context, name string) (*Agent, error) {
	agent := &Agent{}
	err := c.kube.Get(ctx, client.ObjectKey{Namespace: c.namespace, Name: name}, agent)
	return agent, err
}

// FindAgents lists the Agents matching a Kubernetes label selector such as "team=web".
func (c *Client) FindAgents(ctx context.Context, labelSelector string) ([]Agent, error) {
	selector, err := labels.Parse(labelSelector)
	if err != nil {
		return nil, fmt.Errorf("find agents: %w", err)
	}
	list := &AgentList{}
	err = c.kube.List(ctx, list, client.InNamespace(c.namespace), client.MatchingLabelsSelector{Selector: selector})
	return list.Items, err
}

// GetModelCatalog reads the models the subsystem can run (the controller's "default" ModelCatalog).
func (c *Client) GetModelCatalog(ctx context.Context) (*ModelCatalog, error) {
	catalog := &ModelCatalog{}
	err := c.kube.Get(ctx, client.ObjectKey{Namespace: c.namespace, Name: modelCatalogName}, catalog)
	return catalog, err
}

// ApplyAgentDefinition server-side applies an AgentDefinition, taking over fields other managers set.
func (c *Client) ApplyAgentDefinition(ctx context.Context, definition *AgentDefinition) error {
	definition.APIVersion, definition.Kind = SchemeGroupVersion.String(), "AgentDefinition"
	return c.apply(ctx, definition)
}

// ApplyStation server-side applies a Station, taking over fields other managers set.
func (c *Client) ApplyStation(ctx context.Context, station *Station) error {
	station.APIVersion, station.Kind = SchemeGroupVersion.String(), "Station"
	return c.apply(ctx, station)
}

func (c *Client) apply(ctx context.Context, resource client.Object) error {
	if resource.GetName() == "" {
		return fmt.Errorf("apply %s: metadata.name is required", resource.GetObjectKind().GroupVersionKind().Kind)
	}
	resource.SetNamespace(c.namespace)
	resource.SetManagedFields(nil)
	fields, err := runtime.DefaultUnstructuredConverter.ToUnstructured(resource)
	if err != nil {
		return fmt.Errorf("apply %s: %w", resource.GetName(), err)
	}
	configuration := client.ApplyConfigurationFromUnstructured(&unstructured.Unstructured{Object: fields})
	return c.kube.Apply(ctx, configuration, client.FieldOwner(fieldManager), client.ForceOwnership)
}

// IsTerminal reports whether a run has finished (Succeeded or Failed).
func IsTerminal(agent *Agent) bool {
	return agent.Status.Phase == PhaseSucceeded || agent.Status.Phase == PhaseFailed
}

// WaitForAgent polls GetAgent every interval until the run reaches a terminal phase or ctx ends.
func (c *Client) WaitForAgent(ctx context.Context, name string, interval time.Duration) (*Agent, error) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		agent, err := c.GetAgent(ctx, name)
		if err != nil {
			return nil, err
		}
		if IsTerminal(agent) {
			return agent, nil
		}
		select {
		case <-ctx.Done():
			return nil, fmt.Errorf("agent %s did not reach a terminal phase: %w", name, ctx.Err())
		case <-ticker.C:
		}
	}
}
