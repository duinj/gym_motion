import UIKit
import AVFoundation
import Vision

class ViewController: UIViewController, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    // MARK: - Properties
    
    // UI Elements
    @IBOutlet weak var previewView: UIView!
    private var startButton: UIButton!
    private var waveLayer: CAShapeLayer!
    private var repCounterView: UIView!
    private var repCounterLabel: UILabel!
    private var plusOneLabel: UILabel!
    
    // Capture Session
    private let session = AVCaptureSession()
    var bufferSize: CGSize = .zero
    var rootLayer: CALayer!
    private var previewLayer: AVCaptureVideoPreviewLayer!
    private var detectionLayer: CALayer!
    
    // Vision
    private var requests = [VNRequest]()
    
    // Detection
    private let maxPoints = 10
    private var detectedPoints: [DetectedPoint] = []
    var currentState: AlgoState = .IDLE
    private var noneFoundCounter: Int = 0
    private var statCounter: Int = 0
    private var globSecondHalf: Double = 0
    
    // Metrics
    var inferenceTime: CFTimeInterval = 0
    var scaleFactor: CGFloat = 0.0
    var scaleTransform: CGAffineTransform = .identity
    private var lastPointAddedTime: CFTimeInterval = 0
    
    // MARK: - Computed Properties
    
    private var repCount: Int {
        get { UserDefaults.standard.integer(forKey: "repCount") }
        set {
            UserDefaults.standard.set(newValue, forKey: "repCount")
            repCounterLabel.text = "\(newValue)"
        }
    }
    
    // MARK: - Lifecycle Methods
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupStartButton()
        setupWaveLayer()
        setupRepCounter()
    }
    
    // MARK: - Setup Methods
    
    private func setupStartButton() {
        startButton = UIButton(frame: view.bounds)
        startButton.backgroundColor = UIColor(red: 0, green: 0, blue: 0.2, alpha: 1.0)
        startButton.setTitle("Press here to start", for: .normal)
        startButton.setTitleColor(.white, for: .normal)
        startButton.titleLabel?.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        startButton.addTarget(self, action: #selector(startButtonTapped), for: .touchUpInside)
        view.addSubview(startButton)
    }
    
    private func setupWaveLayer() {
        waveLayer = CAShapeLayer()
        waveLayer.fillColor = UIColor.white.withAlphaComponent(0.3).cgColor
        waveLayer.opacity = 0
        view.layer.addSublayer(waveLayer)
    }
    
    private func setupRepCounter() {
        let size: CGFloat = 80
        let margin: CGFloat = 20
        let topMargin: CGFloat = 60
        
        repCounterView = UIView(frame: CGRect(x: view.bounds.width - size - margin,
                                              y: topMargin,
                                              width: size,
                                              height: size))
        repCounterView.backgroundColor = UIColor(red: 0, green: 0, blue: 0.2, alpha: 1.0)
        repCounterView.layer.cornerRadius = size / 2
        view.addSubview(repCounterView)
        
        repCounterLabel = UILabel(frame: repCounterView.bounds)
        repCounterLabel.textAlignment = .center
        repCounterLabel.textColor = .white
        repCounterLabel.font = UIFont.systemFont(ofSize: 32, weight: .bold)
        repCounterLabel.text = "\(repCount)"
        repCounterView.addSubview(repCounterLabel)
        
        plusOneLabel = UILabel(frame: CGRect(x: repCounterView.frame.minX - 40,
                                             y: repCounterView.frame.minY,
                                             width: 40,
                                             height: 40))
        plusOneLabel.textAlignment = .center
        plusOneLabel.textColor = UIColor.systemGreen
        plusOneLabel.font = UIFont.systemFont(ofSize: 24, weight: .bold)
        plusOneLabel.alpha = 0
        view.addSubview(plusOneLabel)
    }
    
    private func setupCamera() {
        let xScale = view.bounds.width / bufferSize.height
        let yScale = view.bounds.height / bufferSize.width
        scaleFactor = max(xScale, yScale)
        scaleTransform = CGAffineTransform(scaleX: scaleFactor, y: -scaleFactor).translatedBy(x: 0, y: -bufferSize.width)
        
        setupCapture()
        setupOutput()
        setupLayers()
        try? setupVision()
        
        session.startRunning()
        
        view.bringSubviewToFront(repCounterView)
        view.bringSubviewToFront(plusOneLabel)
    }
    
    private func setupCapture() {
        guard let videoDevice = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                                 mediaType: .video,
                                                                 position: .back).devices.first else { return }
        do {
            let deviceInput = try AVCaptureDeviceInput(device: videoDevice)
            session.beginConfiguration()
            session.sessionPreset = .vga640x480
            
            guard session.canAddInput(deviceInput) else {
                print("Could not add video device input to the session")
                session.commitConfiguration()
                return
            }
            session.addInput(deviceInput)
            
            try videoDevice.lockForConfiguration()
            let dimensions = CMVideoFormatDescriptionGetDimensions((videoDevice.activeFormat.formatDescription))
            bufferSize.width = CGFloat(dimensions.width)
            bufferSize.height = CGFloat(dimensions.height)
            
            let desiredFrameRate: Double = 20
            videoDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFrameRate))
            videoDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(desiredFrameRate))
            
            videoDevice.unlockForConfiguration()
            session.commitConfiguration()
        } catch {
            print("Error setting up capture: \(error)")
        }
    }
    
    private func setupOutput() {
        let videoDataOutput = AVCaptureVideoDataOutput()
        let videoDataOutputQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated, attributes: [], autoreleaseFrequency: .workItem)
        
        if session.canAddOutput(videoDataOutput) {
            session.addOutput(videoDataOutput)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true
            videoDataOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
        } else {
            print("Could not add video data output to the session")
            session.commitConfiguration()
        }
    }
    
    private func setupLayers() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        rootLayer = previewView.layer
        previewLayer.frame = rootLayer.bounds
        rootLayer.addSublayer(previewLayer)
        
        detectionLayer = CALayer()
        detectionLayer.frame = rootLayer.bounds
        detectionLayer.position = CGPoint(x: rootLayer.bounds.midX, y: rootLayer.bounds.midY)
        rootLayer.addSublayer(detectionLayer)
    }
    
    private func setupVision() throws {
        guard let modelURL = Bundle.main.url(forResource: "yolov8m_50epochs_10additional", withExtension: "mlmodelc") else {
            throw NSError(domain: "ViewController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model file is missing"])
        }
        
        do {
            let visionModel = try VNCoreMLModel(for: MLModel(contentsOf: modelURL))
            let objectRecognition = VNCoreMLRequest(model: visionModel) { [weak self] request, error in
                DispatchQueue.main.async {
                    if let results = request.results {
                        self?.drawResults(results)
                    }
                }
            }
            self.requests = [objectRecognition]
        } catch {
            print("Model loading went wrong: \(error)")
        }
    }
    
    // MARK: - Action Methods
    
    @objc private func startButtonTapped() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        
        animateWave()
        
        UIView.animate(withDuration: 0.5, delay: 0.5, options: .curveEaseOut, animations: {
            self.startButton.alpha = 0
        }) { _ in
            self.startButton.removeFromSuperview()
            self.waveLayer.removeFromSuperlayer()
            self.setupCamera()
        }
    }
    
    private func animateWave() {
        let center = startButton.center
        let radius = sqrt(pow(view.bounds.width, 2) + pow(view.bounds.height, 2))
        
        let startPath = UIBezierPath(arcCenter: center, radius: 0, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        let endPath = UIBezierPath(arcCenter: center, radius: radius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
        
        waveLayer.path = startPath.cgPath
        
        let animation = CABasicAnimation(keyPath: "path")
        animation.toValue = endPath.cgPath
        animation.duration = 0.5
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        
        let opacityAnimation = CAKeyframeAnimation(keyPath: "opacity")
        opacityAnimation.values = [0, 0.6, 0.2, 0]
        opacityAnimation.keyTimes = [0, 0.2, 0.6, 1]
        opacityAnimation.duration = 0.5
        
        let animationGroup = CAAnimationGroup()
        animationGroup.animations = [animation, opacityAnimation]
        animationGroup.duration = 0.5
        animationGroup.fillMode = .forwards
        animationGroup.isRemovedOnCompletion = false
        
        waveLayer.add(animationGroup, forKey: "waveAnimation")
    }
    
    private func incrementRepCount() {
        repCount += 1
        
        plusOneLabel.text = "+1"
        plusOneLabel.alpha = 1
        
        UIView.animate(withDuration: 0.5, delay: 0, options: .curveEaseOut, animations: {
            self.plusOneLabel.frame.origin.y -= 50
            self.plusOneLabel.alpha = 0
        }) { _ in
            self.plusOneLabel.frame.origin.y += 50
        }
    }
    
    // MARK: - Detection Methods
    private var frameCounter: Int = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if frameCounter > 1000 {
            frameCounter = 0
        }
        frameCounter += 1
        
        // Only process every 5th frame
        guard frameCounter % 5 == 0 else { return }
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let imageRequestHandler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do {
            let start = CACurrentMediaTime()
            try imageRequestHandler.perform(self.requests)
            inferenceTime = (CACurrentMediaTime() - start)
        } catch {
            print(error)
        }
    }

    
    func drawResults(_ results: [Any]) {
        DispatchQueue.main.async {
            self.detectionLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        }
        
        for observation in results {
            if let featureValueObservation = observation as? VNCoreMLFeatureValueObservation,
               let multiArray = featureValueObservation.featureValue.multiArrayValue {
                drawDetections(multiArray)
            }
        }
    }
    func drawDetections(_ multiArray: MLMultiArray) {
        let numberOfClasses = 1
        let numberOfBoundingBoxes = 8400
        let confidenceThreshold: Float = 0.8
        let clusteringThreshold: CGFloat = 50.0  // Adjust this value based on your needs

        let modelSize: CGFloat = 640
        let viewWidth = detectionLayer.bounds.width
        let viewHeight = detectionLayer.bounds.height

        let scaleX = viewWidth / modelSize
        let scaleY = viewHeight / modelSize

        var detections: [Detection] = []

        for i in 0..<numberOfBoundingBoxes {
            var maxClassScore: Float = 0
            var maxClassIndex = 0
            
            for j in 0..<numberOfClasses {
                let classScore = Float(truncating: multiArray[[0, 4 + j, i] as [NSNumber]])
                if classScore > maxClassScore {
                    maxClassScore = classScore
                    maxClassIndex = j
                }
            }
            
            if maxClassScore > confidenceThreshold && maxClassIndex == 0 {  // Assuming class 0 is the one we're interested in
                let x = CGFloat(truncating: multiArray[[0, 0, i] as [NSNumber]])
                let y = CGFloat(truncating: multiArray[[0, 1, i] as [NSNumber]])
                detections.append(Detection(score: maxClassScore, x: x, y: y))
            }
        }

        let clusteredDetections = clusterDetections(detections, threshold: clusteringThreshold)
        if clusteredDetections.isEmpty && !detectedPoints.isEmpty {
            noneFoundCounter += 1
            if noneFoundCounter > 7 {
                currentState = .IDLE
            
                // Clear the detectedPoints array
                detectedPoints.removeAll()
            }
        } else{
            noneFoundCounter = 0
            for detection in clusteredDetections {
                let pointX = detection.x * scaleX
                let pointY = detection.y * scaleY
                
                let pointLayer = CAShapeLayer()
                let pointSize: CGFloat = 10
                let pointRect = CGRect(x: pointX - pointSize/2, y: pointY - pointSize/2, width: pointSize, height: pointSize)
                pointLayer.path = UIBezierPath(ovalIn: pointRect).cgPath
                pointLayer.fillColor = UIColor.red.cgColor
                pointLayer.name = "DetectionLayer"
                
                let detectedPoint = DetectedPoint(x: Int(round(pointX)), y: Int(round(pointY)))
                addDetectedPoint(detectedPoint)
                
                DispatchQueue.main.async {
                    self.detectionLayer.addSublayer(pointLayer)
                }
            }
        }
        performCalculationsOnDetectedPoints()
    }
    
    func showToast(message: String, duration: TimeInterval = 0.8) {
        let toastLabel = UILabel()
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        toastLabel.textColor = UIColor.white
        toastLabel.textAlignment = .center
        toastLabel.font = UIFont.systemFont(ofSize: 14.0)
        toastLabel.text = message
        toastLabel.alpha = 0.0
        toastLabel.layer.cornerRadius = 10
        toastLabel.clipsToBounds = true
        
        let toastWidth: CGFloat = 250
        let toastHeight: CGFloat = 35
        toastLabel.frame = CGRect(x: self.view.frame.size.width/2 - toastWidth/2,
                                  y: self.view.frame.size.height - 100,
                                  width: toastWidth, height: toastHeight)
        
        self.view.addSubview(toastLabel)
        
        UIView.animate(withDuration: 0.5, delay: 0.0, options: .curveEaseIn, animations: {
            toastLabel.alpha = 1.0
        }) { _ in
            UIView.animate(withDuration: 0.5, delay: duration, options: .curveEaseOut, animations: {
                toastLabel.alpha = 0.0
            }) { _ in
                toastLabel.removeFromSuperview()
            }
        }
    }

    func clusterDetections(_ detections: [Detection], threshold: CGFloat) -> [Detection] {
        var clusters: [[Detection]] = []

        for detection in detections {
            if let index = clusters.firstIndex(where: { cluster in
                cluster.contains { existingDetection in
                    let distance = hypot(existingDetection.x - detection.x, existingDetection.y - detection.y)
                    return distance < threshold
                }
            }) {
                clusters[index].append(detection)
            } else {
                clusters.append([detection])
            }
        }

        return clusters.map { cluster in
            cluster.max(by: { $0.score < $1.score })!
        }
    }

 

    func addDetectedPoint(_ point: DetectedPoint){
        let currentTime = CACurrentMediaTime()
        //print(currentTime-lastPointAddedTime)
        lastPointAddedTime = CACurrentMediaTime()
        var newPoint = point
        if let lastPoint = detectedPoints.last {
            newPoint.ydiff = lastPoint.y - newPoint.y
        }

        if detectedPoints.count >= maxPoints{
            detectedPoints.removeFirst()
        }
        detectedPoints.append(newPoint)

    }

    
    func calculateStandardDeviation(for points: [DetectedPoint]) -> Double {
        if detectedPoints.count < maxPoints{return 100}
        let count = Double(points.count)
        
        guard count > 1 else {
            return 0 // Standard deviation is undefined for a single point or empty array
        }
        
        let sum = points.reduce(0) { $0 + Double($1.y) }
        let mean = sum / count
        
        let sumOfSquaredDifferences = points.reduce(0) { (result, point) -> Double in
            let difference = Double(point.y) - mean
            return result + (difference * difference)
        }
        let variance = sumOfSquaredDifferences / (count - 1)
        
        return sqrt(variance)
    }

    func isTurningPoint(_ window: [Int]) -> Bool {
        let firstHalf = window[0..<window.count/2]
        let secondHalf = window[window.count/2 + 1..<window.count]
        
        let firstHalfTrend = trend(of: firstHalf)
        let secondHalfTrend = trend(of: secondHalf)
    
        if secondHalfTrend*globSecondHalf < 0 && globSecondHalf != 0 && firstHalfTrend * secondHalfTrend < 0 && abs(firstHalfTrend - secondHalfTrend) > 10 && firstHalfTrend < secondHalfTrend{
            globSecondHalf = secondHalfTrend
            return true
        }else{
            globSecondHalf = secondHalfTrend
            return false
        }
        
          
    }

    func trend(of values: ArraySlice<Int>) -> Double {
        let x = Array(0..<values.count)
        let y = Array(values)
        
        let sumX = x.reduce(0, +)
        let sumY = y.reduce(0, +)
        let sumXY = zip(x, y).map(*).reduce(0, +)
        let sumX2 = x.map { $0 * $0 }.reduce(0, +)
        
        let n = Double(x.count)
        let slope = (n * Double(sumXY) - Double(sumX * sumY)) /
                    (n * Double(sumX2) - Double(sumX * sumX))
        
        return slope
    }
    
    func performCalculationsOnDetectedPoints() {
        

        switch currentState {
            case .IDLE:
                let standardDeviation = calculateStandardDeviation(for: detectedPoints)
                //print("The standard deviation of y values is: \(standardDeviation)")
            if standardDeviation < 5 { statCounter+=1 }
            else{ statCounter = 0}
            if statCounter > 10 { currentState = .STATIC
                DispatchQueue.main.async {
                              self.showToast(message: "Movement can now start")
                          }

            }
            case .STATIC:

       
            currentState = .MOVE
   
            case .MOVE:
            let ydiffValues = detectedPoints.map { $0.y }
            //print("\(ydiffValues[9]), \(ydiffValues[8])")
            
            //print("Turning points found at indices: \(turningPoints)")
            if isTurningPoint(ydiffValues.suffix(9)) {
                DispatchQueue.main.async {
                    
                    self.incrementRepCount()
                           }
                   

            }

        }
    }
    
    // MARK: - Cleanup
    
    func teardownAVCapture() {
        previewLayer.removeFromSuperlayer()
        previewLayer = nil
    }
}

// MARK: - Supporting Types

struct DetectedPoint {
    let x: Int
    let y: Int
    var ydiff: Int = 0
}

struct Detection {
    let score: Float
    let x: CGFloat
    let y: CGFloat
}

enum AlgoState {
    case IDLE
    case STATIC
    case MOVE
}
