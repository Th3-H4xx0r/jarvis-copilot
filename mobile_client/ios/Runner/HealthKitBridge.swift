import Flutter
import HealthKit
import UIKit

/// MethodChannel for the `read_healthkit` skill.
///
/// Usage from Dart:
///   await MethodChannel('jarviscopilot/healthkit').invokeMethod('read', {
///     'metric': 'steps' | 'heart_rate' | 'sleep' | 'workouts',
///     'days': 1..30,
///   })
///
/// Permissions are requested lazily on the first call so the user only
/// sees the HealthKit prompt when the agent actually needs the data.
class HealthKitBridge {
    private static let store = HKHealthStore()

    static func register(with controller: FlutterViewController) {
        let channel = FlutterMethodChannel(
            name: "jarviscopilot/healthkit",
            binaryMessenger: controller.binaryMessenger
        )
        channel.setMethodCallHandler { (call, result) in
            switch call.method {
            case "read":
                guard let args = call.arguments as? [String: Any],
                      let metric = args["metric"] as? String else {
                    result(FlutterError(code: "bad_args", message: "metric required", details: nil))
                    return
                }
                let days = (args["days"] as? Int) ?? 1
                self.read(metric: metric, days: days, result: result)
            default:
                result(FlutterMethodNotImplemented)
            }
        }
    }

    private static func read(metric: String, days: Int, result: @escaping FlutterResult) {
        guard HKHealthStore.isHealthDataAvailable() else {
            result(["error": "HealthKit unavailable"])
            return
        }
        let (sampleType, unit, reducer): (HKSampleType?, HKUnit?, ((HKQuantity) -> Double)?) = {
            switch metric {
            case "steps":
                return (HKObjectType.quantityType(forIdentifier: .stepCount), HKUnit.count(),
                        { $0.doubleValue(for: .count()) })
            case "heart_rate":
                return (HKObjectType.quantityType(forIdentifier: .heartRate),
                        HKUnit.count().unitDivided(by: HKUnit.minute()),
                        { $0.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())) })
            case "sleep":
                return (HKObjectType.categoryType(forIdentifier: .sleepAnalysis), nil, nil)
            case "workouts":
                return (HKObjectType.workoutType(), nil, nil)
            default:
                return (nil, nil, nil)
            }
        }()
        guard let type = sampleType else {
            result(["error": "unknown metric: \(metric)"])
            return
        }
        let readSet: Set<HKObjectType> = [type]
        store.requestAuthorization(toShare: nil, read: readSet) { ok, err in
            guard ok else {
                result(["error": err?.localizedDescription ?? "permission denied"])
                return
            }
            let end = Date()
            let start = Calendar.current.date(byAdding: .day, value: -days, to: end) ?? end
            let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
            let q = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: 256, sortDescriptors: nil
            ) { _, samples, qerr in
                if let qerr = qerr {
                    result(["error": qerr.localizedDescription]); return
                }
                let arr = samples ?? []
                var out: [[String: Any]] = []
                for s in arr {
                    if let q = s as? HKQuantitySample, let r = reducer, let unit = unit {
                        out.append([
                            "value": r(q.quantity),
                            "unit": unit.unitString,
                            "start": ISO8601DateFormatter().string(from: q.startDate),
                            "end": ISO8601DateFormatter().string(from: q.endDate),
                        ])
                    } else if let c = s as? HKCategorySample {
                        out.append([
                            "value": c.value,
                            "start": ISO8601DateFormatter().string(from: c.startDate),
                            "end": ISO8601DateFormatter().string(from: c.endDate),
                        ])
                    } else if let w = s as? HKWorkout {
                        out.append([
                            "activity": "\(w.workoutActivityType.rawValue)",
                            "duration_s": w.duration,
                            "start": ISO8601DateFormatter().string(from: w.startDate),
                            "end": ISO8601DateFormatter().string(from: w.endDate),
                        ])
                    }
                }
                result(["samples": out, "count": out.count])
            }
            store.execute(q)
        }
    }
}
