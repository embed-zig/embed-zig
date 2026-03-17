const std = @import("std");
const embed = @import("embed");
const module = embed.pkg.event.motion.motion;
const types = module.types;
const Axis = module.Axis;
const Orientation = module.Orientation;
const ShakeData = module.ShakeData;
const TapData = module.TapData;
const TiltData = module.TiltData;
const FlipData = module.FlipData;
const FreefallData = module.FreefallData;
const MotionAction = module.MotionAction;
const MotionEvent = module.MotionEvent;
const AccelData = module.AccelData;
const GyroData = module.GyroData;
const SensorSample = module.SensorSample;
const Thresholds = module.Thresholds;
const accelFrom = module.accelFrom;
const gyroFrom = module.gyroFrom;
const detector = module.detector;
const Detector = module.Detector;

test {
    _ = types;
    _ = detector;
}
