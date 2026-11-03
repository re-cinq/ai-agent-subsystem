"""The part of the ``kubernetes`` package the client calls, so any object with these methods works."""

from typing import Any, Protocol


class CustomObjects(Protocol):
    """The part of ``kubernetes.client.CustomObjectsApi`` the client uses."""

    def create_namespaced_custom_object(self, group: str, version: str, namespace: str, plural: str,
                                        body: dict[str, Any], **kwargs: Any) -> Any: ...

    def get_namespaced_custom_object(self, group: str, version: str, namespace: str, plural: str,
                                     name: str, **kwargs: Any) -> Any: ...

    def list_namespaced_custom_object(self, group: str, version: str, namespace: str, plural: str,
                                      **kwargs: Any) -> Any: ...

    def patch_namespaced_custom_object(self, group: str, version: str, namespace: str, plural: str,
                                       name: str, body: Any, **kwargs: Any) -> Any: ...
