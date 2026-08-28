import Speech
import Foundation

let sem = DispatchSemaphore(value: 0)
Task {
    print("isAvailable:", SpeechTranscriber.isAvailable)
    print("supported(first 8):", await SpeechTranscriber.supportedLocales.map(\.identifier).prefix(8))
    print("installedLocales:", await SpeechTranscriber.installedLocales.map(\.identifier))
    let t = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
    print("assetStatus:", await AssetInventory.status(forModules: [t]))
    print("reservedLocales:", await AssetInventory.reservedLocales.map(\.identifier))
    print("maxReserved:", AssetInventory.maximumReservedLocales)
    sem.signal()
}
sem.wait()
