"""Fast computer control: a decision model drives the user's Mac one move at a time.

``choices`` turns a numbered screenshot's elements into the options a decision
model picks from, ``decide`` asks the decision model (or the fallback vision
model), ``mac`` talks to jc-client's ``ui_look`` / ``ui_do`` skills, ``loop``
runs look → decide → act, and ``turns`` binds a harness Computer node to a turn.
"""
