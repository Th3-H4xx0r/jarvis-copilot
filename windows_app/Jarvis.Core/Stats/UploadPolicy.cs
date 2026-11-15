namespace Jarvis.Core.Stats;

/// How often samples go to the server: every second while someone watches live (the server says
/// so in each reply), else as 10-second averages.
public static class UploadPolicy
{
    public static readonly TimeSpan Live = TimeSpan.FromSeconds(1), Batched = TimeSpan.FromSeconds(10);

    public static TimeSpan NextDelay(bool live) => live ? Live : Batched;

    /// The average of several samples (the batch's 10-second point), stamped with the last time.
    public static StatsSample Average(IReadOnlyList<StatsSample> samples)
    {
        if (samples.Count == 0) throw new ArgumentException("no samples");
        var keys = samples.SelectMany(s => s.R.Keys).Distinct();
        var avg = keys.ToDictionary(k => k, k => Math.Round(samples.Where(s => s.R.ContainsKey(k)).Average(s => s.R[k]), 2));
        return new StatsSample(samples[^1].T, avg, samples[^1].Game);
    }
}
