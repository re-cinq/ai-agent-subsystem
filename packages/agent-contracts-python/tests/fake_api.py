"""An in-memory stand-in for kubernetes.client.CustomObjectsApi: stores objects per
(namespace, plural, name) and records every call."""

import copy
import inspect
from typing import Any

from kubernetes.client import CustomObjectsApi
from kubernetes.client.exceptions import ApiException


def _real_signature(method):
    """Fails a call whose arguments the real CustomObjectsApi method would reject."""
    real = inspect.signature(getattr(CustomObjectsApi, method.__name__))

    def checked(self, *args, **kwargs):
        real.bind(self, *args, **kwargs)
        return method(self, *args, **kwargs)
    return checked


class FakeCustomObjects:
    def __init__(self) -> None:
        self.objects: dict[tuple[str, str, str], dict[str, Any]] = {}
        self.patches: list[dict[str, Any]] = []
        self.generated = 0

    @_real_signature
    def create_namespaced_custom_object(self, group, version, namespace, plural, body, **kwargs):
        stored = copy.deepcopy(body)
        metadata = stored.setdefault("metadata", {})
        if "name" not in metadata:
            self.generated += 1
            metadata["name"] = f"{metadata['generateName']}{self.generated}"
        metadata["namespace"] = namespace
        self.objects[(namespace, plural, metadata["name"])] = stored
        return copy.deepcopy(stored)

    @_real_signature
    def get_namespaced_custom_object(self, group, version, namespace, plural, name, **kwargs):
        if (namespace, plural, name) not in self.objects:
            raise ApiException(status=404, reason="Not Found")
        return copy.deepcopy(self.objects[(namespace, plural, name)])

    @_real_signature
    def list_namespaced_custom_object(self, group, version, namespace, plural, label_selector="", **kwargs):
        key, _, value = label_selector.partition("=")
        items = [copy.deepcopy(stored) for (space, kind, _), stored in self.objects.items()
                 if space == namespace and kind == plural
                 and stored.get("metadata", {}).get("labels", {}).get(key) == value]
        return {"items": items}

    @_real_signature
    def patch_namespaced_custom_object(self, group, version, namespace, plural, name, body, **kwargs):
        self.patches.append({"path": (group, version, namespace, plural, name), "body": body, **kwargs})
        self.objects[(namespace, plural, name)] = copy.deepcopy(body)
        return copy.deepcopy(body)
