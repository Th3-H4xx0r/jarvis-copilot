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


def action_output(out_uuid, out_name):
    """A whole-value reference to a prior action's output (the Split Text list, a
    Get-Item-from-List result, …) — used as a WFInput."""
    return {"Value": {"OutputUUID": out_uuid, "Type": "ActionOutput",
                      "OutputName": out_name},
            "WFSerializationType": "WFTextTokenAttachment"}


def token_string(out_uuid, out_name):
    """A TEXT FIELD whose entire content is one variable. The Object-Replacement
    char (U+FFFC) marks where the attachment sits in the string. Send Message's
    recipient and body are token-string text fields (not whole-value inputs), so
    a variable dropped into them serializes this way."""
    return token_string_multi([(out_uuid, out_name)])


def token_string_multi(parts):
    """Build a token-string text field from a mix of literal strings and
    (output_uuid, output_name) variable tokens. Each variable occupies one
    Object-Replacement char in the string; attachmentsByRange maps "{index, 1}"
    -> the attachment at that char."""
    s = ""
    attachments = {}
    for p in parts:
        if isinstance(p, str):
            s += p
        else:
            attachments["{%d, 1}" % len(s)] = {
                "OutputUUID": p[0], "Type": "ActionOutput", "OutputName": p[1]}
            s += "￼"
    return {"Value": {"string": s, "attachmentsByRange": attachments},
            "WFSerializationType": "WFTextTokenString"}


def send_message_actions():
    """JC Send Message — input is "recipient|message". Split on '|', send the
    SECOND part (body) to the FIRST part (recipient). Recipient is normally a bare
    phone number (the app resolves a contact name to a number first, and a number
    needs no contact conversion); a contact name also works if it matches.

    The whole texting bug was a HAND-BUILT shortcut feeding the *unsplit*
    "recipient|message" string straight into Recipients — so Send Message got
    "+1510…|hi" and failed to convert it to a contact. Here the Split Text + First/
    Last-Item extraction is explicit and bulletproof, so Recipients gets a clean
    value."""
    split_u, rec_u, msg_u = U(), U(), U()
    actions = [
        act("is.workflow.actions.text.split", {
            "WFInput": EXT_INPUT,
            "WFTextSeparator": "Custom",
            "WFTextCustomSeparator": "|",
            "UUID": split_u,
        }),
        act("is.workflow.actions.getitemfromlist", {
            "WFInput": action_output(split_u, "Split Text"),
            "WFItemSpecifier": "First Item",
            "UUID": rec_u,
        }),
        act("is.workflow.actions.getitemfromlist", {
            "WFInput": action_output(split_u, "Split Text"),
            "WFItemSpecifier": "Last Item",
            "UUID": msg_u,
        }),
    ]
    # JC_DEBUG=1: show what the split produced BEFORE sending, to confirm the
    # recipient/body variables actually bind (the bisection method). Remove for
    # the production build.
    if os.environ.get("JC_DEBUG"):
        actions.append(act("is.workflow.actions.notification", {
            "WFNotificationActionBody": token_string_multi(
                ["to=[", (rec_u, "Item from List"), "] msg=[",
                 (msg_u, "Item from List"), "]"]),
            "WFNotificationActionTitle": "JC Send Message DEBUG",
            "UUID": U(),
        }))
    actions.append(act("is.workflow.actions.sendmessage", {
        "WFSendMessageContent": token_string(msg_u, "Item from List"),
        "WFSendMessageActionRecipients": token_string(rec_u, "Item from List"),
        "UUID": U(),
    }))
    return actions

INPUT_CLASSES = [
    "WFAppContentItem", "WFAppStoreAppContentItem", "WFArticleContentItem",
    "WFContactContentItem", "WFDateContentItem", "WFEmailAddressContentItem",
    "WFFolderContentItem", "WFGenericFileContentItem", "WFImageContentItem",
    "WFiTunesProductContentItem", "WFLocationContentItem", "WFDCMapsLinkContentItem",
    "WFAVAssetContentItem", "WFPDFContentItem", "WFPhoneNumberContentItem",
    "WFRichTextContentItem", "WFSafariWebPageContentItem", "WFStringContentItem",
    "WFURLContentItem",
]


def _consumes_input(actions):
    """True if any action reads the Shortcut Input (ExtensionInput). The editor
    sets WFWorkflowHasShortcutInputVariables True in that case; leaving it False
    can make the input arrive EMPTY (the suspected cause of the earlier empty-
    input shortcut), so we mirror the editor and set it automatically."""
    import json
    return "ExtensionInput" in json.dumps(actions)


def wrap(actions):
    return {
        "WFQuickActionSurfaces": [],
        "WFWorkflowActions": actions,
        "WFWorkflowClientVersion": "4610",
        "WFWorkflowHasOutputFallback": False,
        "WFWorkflowHasShortcutInputVariables": _consumes_input(actions),
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
    # Open ANY installed app BY NAME via the system "Open App" action (what Siri
    # does) — not limited to URL schemes. Input (text) is the app name; "Open
    # App" coerces it to the matching app. This is the fallback open_app uses
    # when iOS has no URL scheme for the requested app (e.g. bank apps).
    "JC Open App":   [act("is.workflow.actions.openapp",
                          {"WFAppIdentifier": EXT_INPUT, "UUID": U()})],
    "JC Send Message": send_message_actions(),
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
