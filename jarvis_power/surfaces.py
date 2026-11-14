"""Every place on a device that belongs to a Power integration and hides while it's off.

An integration lists its surface ids in ``surfaces``; each id must be here, with
where it lives, so the next person adding a device check knows the place exists and
what it's called. Devices gate by integration id (``PowerState.isOn("dashcam")``);
these ids are the documented map of where those checks sit.
"""

CATALOG: dict[str, str] = {}
