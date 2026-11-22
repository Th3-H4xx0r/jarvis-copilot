// Jarvis Glasses camera: adapted from VCamNetSample (https://github.com/smourier/VCamNetSample).
// Copyright (c) 2024-2026 Simon Mourier. MIT License; the full notice is in THIRD_PARTY_NOTICES.md.
using System.Runtime.InteropServices;
using DirectN;
using Jarvis.Core.GlassesCamera;
using JarvisGlassesCam.Utilities;

namespace JarvisGlassesCam
{
    /// The COM class Windows' camera service activates for the "Jarvis Glasses" virtual camera
    /// (MFCreateVirtualCamera's source id is this CLSID): hands out the media source.
    [ComVisible(true), Guid(GlassesCamSpec.SourceClsid)]
    public class Activator : MFAttributes, IMFActivateImpl, ICustomQueryInterface
    {
        public Activator()
        {
            EventProvider.LogInfo($"ctor commandLine:{Environment.CommandLine}");
            SetDefaultAttributes(this);
        }

        private static void SetDefaultAttributes(IMFAttributes attributes)
        {
            attributes.SetUINT32(MFConstants.MF_VIRTUALCAMERA_PROVIDE_ASSOCIATED_CAMERA_SOURCES, 1).ThrowOnError();
            attributes.SetGUID(MFConstants.MFT_TRANSFORM_CLSID_Attribute, typeof(Activator).GUID).ThrowOnError();
        }

        public HRESULT ActivateObject(Guid riid, out nint ppv)
        {
            try
            {
                EventProvider.LogInfo($"{riid}");
                if (riid == typeof(IMFMediaSourceEx).GUID || riid == typeof(IMFMediaSource).GUID)
                {
                    var source = new MediaSource();
                    SetDefaultAttributes(source);
                    ppv = ComObject.QueryObjectInterface(source, riid, false);
                    if (ppv != IntPtr.Zero)
                        return HRESULTS.S_OK;
                }

                ppv = 0;
                EventProvider.LogInfo($"{riid} => E_NOINTERFACE");
                return HRESULTS.E_NOINTERFACE;
            }
            catch (Exception e)
            {
                EventProvider.LogError(e.ToString());
                throw;
            }
        }

        public HRESULT ShutdownObject()
        {
            EventProvider.LogInfo();
            return HRESULTS.S_OK;
        }

        public HRESULT DetachObject()
        {
            EventProvider.LogInfo();
            return HRESULTS.S_OK;
        }

        public CustomQueryInterfaceResult GetInterface(ref Guid iid, out nint ppv)
        {
            EventProvider.LogInfo($"iid{iid:B}");
            ppv = 0;
            return CustomQueryInterfaceResult.NotHandled;
        }
    }
}
