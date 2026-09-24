"""Soniox responses → live words, finished lines, and translations that arrive late."""
from jarvis_speech.assemble import TokenAssembler


class Rec:
    def __init__(self):
        self.partials, self.segs, self.trans, self.errors = [], [], [], []

    def on_partial(self, text, start_ms, speaker, language):
        self.partials.append((text, start_ms, speaker, language))

    def on_segment(self, seg):
        self.segs.append(seg)

    def on_translation(self, key, text):
        self.trans.append((key, text))

    def on_error(self, message):
        self.errors.append(message)


def tok(text, s=None, e=None, final=True, spk="1", lang="en", status="none"):
    t = {"text": text, "is_final": final, "speaker": spk, "language": lang, "translation_status": status}
    if s is not None:
        t["start_ms"], t["end_ms"] = s, e
    return t


def test_subwords_join_and_end_closes_segment():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Hel", 0, 100), tok("lo", 100, 200), tok(" there", 200, 400), tok("<end>")]})
    assert [s.text for s in r.segs] == ["Hello there"]
    assert (r.segs[0].start_ms, r.segs[0].end_ms, r.segs[0].speaker, r.segs[0].language) == (0, 400, "1", "en")


def test_nonfinal_tokens_are_partials_not_segments():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Good", 0, 100), tok(" morn", 100, 200, final=False)]})
    assert r.segs == [] and r.partials[-1][0] == "Good morn"


def test_same_partial_is_not_repeated():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Hi", 0, 100, final=False)]})
    a.consume({"tokens": [tok("Hi", 0, 100, final=False)]})
    assert len(r.partials) == 1


def test_speaker_change_splits():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Hi", 0, 100, spk="1"), tok(" you", 100, 200, spk="2"), tok("<end>")]})
    assert [(s.text, s.speaker) for s in r.segs] == [("Hi", "1"), ("you", "2")]


def test_translation_follows_its_segment_even_after_end():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Hola", 0, 300, lang="es", status="original"), tok("<end>")]})
    a.consume({"tokens": [tok("Hel", lang="en", status="translation"), tok("lo", lang="en", status="translation")]})
    assert r.segs[0].text == "Hola" and r.segs[0].language == "es"
    assert r.trans[-1] == (r.segs[0].key, "Hello")


def test_translation_before_close_rides_on_the_segment():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Hola", 0, 300, lang="es", status="original"),
                          tok("Hello", lang="en", status="translation"), tok("<end>")]})
    assert r.segs[0].translation == "Hello" and r.trans == []


def test_language_is_majority_by_duration():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("ok", 0, 100, lang="en"), tok(" vamos a la playa", 100, 1500, lang="es"), tok("<fin>")]})
    assert r.segs[0].language == "es"


def test_flush_closes_open_final_tokens():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("tail", 0, 200)]})
    a.flush()
    assert [s.text for s in r.segs] == ["tail"]


def test_times_run_through_to_session():
    r = Rec()
    a = TokenAssembler(r, to_session=lambda ms: ms + 5000)
    a.consume({"tokens": [tok("x", 100, 300), tok("<end>")]})
    assert (r.segs[0].start_ms, r.segs[0].end_ms) == (5100, 5300)


def test_error_response_reaches_sink():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [], "error_code": 401, "error_type": "unauthenticated", "error_message": "bad key"})
    assert r.errors and "unauthenticated" in r.errors[0]


def test_a_translation_after_a_speaker_split_goes_to_the_first_line():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Hola", 0, 300, spk="1", lang="es", status="original"),
                          tok(" amigo", 300, 700, spk="2", lang="es", status="original"),
                          tok("<end>")]})
    a.consume({"tokens": [tok("Hello friend", lang="en", status="translation")]})
    assert [s.text for s in r.segs] == ["Hola", "amigo"]
    assert r.trans == [(r.segs[0].key, "Hello friend")]


def test_words_the_engine_was_unsure_of_travel_with_the_line():
    # On the Pod's far-field clips, the words Soniox scored low were the wrong ones
    # ("an email with a phone(0.64)" for "a poem").
    r = Rec()
    a = TokenAssembler(r)
    toks = [dict(tok(t, i * 100, i * 100 + 90), confidence=c) for i, (t, c) in enumerate(
        [("Send", 0.98), (" me", 0.97), (" an", 0.95), (" e", 0.93), ("mail", 0.9), (" with", 0.8),
         (" a", 0.66), (" pho", 0.5), ("ne?", 0.64)])]
    a.consume({"tokens": toks + [tok("<end>")]})
    assert r.segs[0].text == "Send me an email with a phone?"
    assert r.segs[0].unsure == ("a", "phone")


def test_a_line_without_confidences_is_sure():
    r = Rec()
    a = TokenAssembler(r)
    a.consume({"tokens": [tok("Hello", 0, 100), tok("<end>")]})
    assert r.segs[0].unsure == ()
