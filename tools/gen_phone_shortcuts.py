#!/usr/bin/env python3
"""Generate the per-verb "JC <Verb>" phone-control Shortcuts for JarvisCopilot.

WHY PER-VERB (and not one JSON dispatcher): on-device testing proved two iOS
Shortcuts primitives unreliable for a single dispatcher:
  * `Get Dictionary from Input` returns an EMPTY dictionary for a multi-key JSON
    payload delivered via x-callback `input=text` (single-key sometimes worked,
    multi-key did not) — so key lookups got nothing.
  * the `If` action would not reliably branch on a verb string even when fed a
    clean value from `Split Text`.
So each verb is its own tiny Shortcut built from ONLY bulletproof primitives:
    raw text input  ->  Get Numbers from Input  ->  the one action
No dictionary, no key lookup, no conditional, no value coercion anywhere. The
Flutter app (lib/skills/phone_command.dart) picks the Shortcut by name and sends
the value as plain text (e.g. "0.3", "1", "spotify://").

USAGE (needs a Mac — `shortcuts sign` is macOS-only):
    python3 tools/gen_phone_shortcuts.py            # writes unsigned plists to /tmp/jcskills
    # then sign each so iOS 15+ will import it:
    for f in /tmp/jcskills/*.unsigned.shortcut; do
      name="$(basename "${f%.unsigned.shortcut}")"
      plutil -convert binary1 "$f"
      shortcuts sign --mode people-who-know-me --input "$f" \
        --output "$HOME/Downloads/${name}.shortcut"
    done
Then AirDrop the signed ~/Downloads/JC*.shortcut files to the phone -> Add.
The shortcut NAME is taken from the filename, so it must match
verbShortcutNames in phone_command.dart exactly.
"""
import os
import plistlib
import uuid


def U():
    return str(uuid.uuid4()).upper()


def act(ident, params):
    return {"WFWorkflowActionIdentifier": ident, "WFWorkflowActionParameters": params}


def num_var(out_uuid):
    """A plain (uncoerced) reference to a Get-Numbers output — feeding a NUMBER,
    not a string, is what makes Set Brightness/Volume actually apply."""
    return {"Value": {"OutputUUID": out_uuid, "Type": "ActionOutput",
                      "OutputName": "Number"},
            "WFSerializationType": "WFTextTokenAttachment"}


# The Shortcut Input (the x-callback `text=` payload) as a magic variable.
EXT_INPUT = {"Value": {"Type": "ExtensionInput"},
             "WFSerializationType": "WFTextTokenAttachment"}

INPUT_CLASSES = [
    "WFAppContentItem", "WFAppStoreAppContentItem", "WFArticleContentItem",
    "WFContactContentItem", "WFDateContentItem", "WFEmailAddressContentItem",
    "WFFolderContentItem", "WFGenericFileContentItem", "WFImageContentItem",
    "WFiTunesProductContentItem", "WFLocationContentItem", "WFDCMapsLinkContentItem",
    "WFAVAssetContentItem", "WFPDFContentItem", "WFPhoneNumberContentItem",
    "WFRichTextContentItem", "WFSafariWebPageContentItem", "WFStringContentItem",
    "WFURLContentItem",
]


def wrap(actions):
    return {
        "WFQuickActionSurfaces": [],
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "4610",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": False,
        "WFWorkflowIcon": {"WFWorkflowIconGlyphNumber": 61440,
                           "WFWorkflowIconStartColor": -1263359489},
        "WFWorkflowImportQuestions": [],
        "WFWorkflowInputContentItemClasses": INPUT_CLASSES,
        "WFWorkflowMinimumClientVersion": 900,
        "WFWorkflowMinimumClientVersionString": "900",
        "WFWorkflowOutputContentItemClasses": [],
        "WFWorkflowTypes": ["WFWorkflowTypeShowInSearch"],
    }


def number_then(action_id, pkey, extra=None):
    """Get Numbers from Input -> <action> with the parsed number bound to pkey."""
    n = U()
    params = {pkey: num_var(n), "UUID": U()}
    if extra:
        params.update(extra)
    return [act("is.workflow.actions.detect.number", {"UUID": n}),
            act(action_id, params)]


# Each name MUST match verbShortcutNames in phone_command.dart.
SKILLS = {
    "JC Brightness": number_then("is.workflow.actions.setbrightness", "WFBrightness"),
    "JC Volume":     number_then("is.workflow.actions.setvolume",     "WFVolume"),
    "JC WiFi":       number_then("is.workflow.actions.wifi.set",      "OnValue"),
    "JC Bluetooth":  number_then("is.workflow.actions.bluetooth.set", "OnValue"),
    "JC Focus":      number_then("is.workflow.actions.dnd.set",       "Enabled",
                                 {"AssertionType": "Turned Off"}),
    "JC Open URL":   [act("is.workflow.actions.openurl",
                          {"WFInput": EXT_INPUT, "UUID": U()})],
}


def main():
    out_dir = "/tmp/jcskills"
    os.makedirs(out_dir, exist_ok=True)
    for name, actions in SKILLS.items():
        path = os.path.join(out_dir, f"{name}.unsigned.shortcut")
        with open(path, "wb") as fh:
            plistlib.dump(wrap(actions), fh)
        print("wrote", path)


if __name__ == "__main__":
    main()
