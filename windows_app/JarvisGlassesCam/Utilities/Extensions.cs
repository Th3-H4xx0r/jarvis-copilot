// Jarvis Glasses camera: adapted from VCamNetSample (https://github.com/smourier/VCamNetSample).
// Copyright (c) 2024-2026 Simon Mourier. MIT License; the full notice is in THIRD_PARTY_NOTICES.md.
using DirectN;

namespace JarvisGlassesCam.Utilities
{
    internal static class Extensions
    {
        public static string GetMFName(this Guid guid) => typeof(MFConstants).GetGuidName(guid);
        public static string GetMFName(this KSIDENTIFIER id) => typeof(MFConstants).GetGuidName(id.__union_0.__field_0.Set) + " " + id.__union_0.__field_0.Id;
    }
}
