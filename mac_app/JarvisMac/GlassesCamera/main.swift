import CoreMediaIO
import Foundation

// The Jarvis Glasses camera extension: start the provider and serve until macOS stops it.
let providerSource = GlassesCameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
