namespace Jarvis.Core.Model;

/// What a session is doing, from its hooks (desktop_client/jc_client/agent_engine.py).
public enum SessionState { Idle, Thinking, Working, Approval, Question, RateLimit, Finished, Error }

public enum OrbMood { Idle, Working, Waiting, Finished, Error, RateLimit }

public static class SessionStates
{
    public static SessionState Parse(string raw) => raw switch
    {
        "thinking" => SessionState.Thinking,
        "working" => SessionState.Working,
        "approval" => SessionState.Approval,
        "question" => SessionState.Question,
        "ratelimit" => SessionState.RateLimit,
        "finished" => SessionState.Finished,
        "error" => SessionState.Error,
        _ => SessionState.Idle,
    };

    public static int Urgency(this SessionState s) => s switch
    {
        SessionState.Approval or SessionState.Question => 0,
        SessionState.Error => 1,
        SessionState.RateLimit => 2,
        SessionState.Working or SessionState.Thinking => 3,
        SessionState.Finished => 4,
        _ => 5,
    };

    public static OrbMood Mood(this SessionState s) => s switch
    {
        SessionState.Thinking or SessionState.Working => OrbMood.Working,
        SessionState.Approval or SessionState.Question => OrbMood.Waiting,
        SessionState.Finished => OrbMood.Finished,
        SessionState.Error => OrbMood.Error,
        SessionState.RateLimit => OrbMood.RateLimit,
        _ => OrbMood.Idle,
    };

    public static string Label(this SessionState s) => s switch
    {
        SessionState.Thinking => "Thinking",
        SessionState.Working => "Working",
        SessionState.Approval => "Needs approval",
        SessionState.Question => "Has a question",
        SessionState.RateLimit => "Rate-limited",
        SessionState.Finished => "Finished",
        SessionState.Error => "Failed",
        _ => "Idle",
    };
}
