//
//  reader.swift
//  Stats
//
//  Created by Serhiy Mytrovtsiy on 01.06.2019.
//  Copyright © 2019 Serhiy Mytrovtsiy. All rights reserved.
//

import Foundation

struct MemoryUsage {
    var total: Double = 0
    var used: Double = 0
    var free: Double = 0
}

class MemoryReader: Reader {
    public var value: Observable<[Double]>!
    public var usage: Observable<MemoryUsage> = Observable(MemoryUsage())
    public var processes: Observable<[TopProcess]> = Observable([TopProcess]())
    public var available: Bool = true
    public var availableAdditional: Bool = true
    public var totalSize: Float
    public var updateInterval: Int = 0
    
    private var timer: Repeater?
    private var additionalTimer: Repeater?
    
    init() {
        self.value = Observable([])
        var stats = host_basic_info()
        var count = UInt32(MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            self.totalSize = Float(stats.max_mem)
        }
        else {
            self.totalSize = 0
            print("Error with host_info(): " + (String(cString: mach_error_string(kerr), encoding: String.Encoding.ascii) ?? "unknown error"))
        }
        
        if self.available {
            self.read()
        }
        
        self.timer = Repeater.init(interval: .seconds(1), observer: { _ in
            self.read()
        })
        self.additionalTimer = Repeater.init(interval: .seconds(1), observer: { _ in
            self.readAdditional()
        })
    }
    
    func start() {
        read()
        if self.timer != nil && self.timer!.state.isRunning == false {
            self.timer!.start()
        }
    }
    
    func stop() {
        self.timer?.pause()
    }
    
    func startAdditional() {
        readAdditional()
        if self.additionalTimer != nil && self.additionalTimer!.state.isRunning == false {
            self.additionalTimer!.start()
        }
    }
    
    func stopAdditional() {
        self.additionalTimer?.pause()
    }
    
    @objc func readAdditional() {
        let task = Process()
        task.launchPath = "/usr/bin/top"
        task.arguments = ["-l", "1", "-o", "mem", "-n", "5", "-stats", "pid,command,mem"]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        
        task.standardOutput = outputPipe
        task.standardError = errorPipe
        
        do {
            try task.run()
        } catch let error {
            print(error)
        }
        
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        _ = String(decoding: errorData, as: UTF8.self)
        
        if output.isEmpty {
            return
        }
        
        var processes: [TopProcess] = []
        output.enumerateLines { (line, stop) -> () in
            if line.matches("^\\d+ + .+ +\\d+.\\d[M\\+\\-]+ *$") {
                var str = line.trimmingCharacters(in: .whitespaces)
                let pidString = str.findAndCrop(pattern: "^\\d+")
                let usageString = str.findAndCrop(pattern: " [0-9]+M(\\+|\\-)*$")
                var command = str.trimmingCharacters(in: .whitespaces)
                
                if let regex = try? NSRegularExpression(pattern: " (\\+|\\-)*$", options: .caseInsensitive) {
                    command = regex.stringByReplacingMatches(in: command, options: [], range: NSRange(location: 0, length:  command.count), withTemplate: "")
                }
                
                let pid = Int(pidString) ?? 0
                guard let usage = Double(usageString.filter("01234567890.".contains)) else {
                    return
                }
                let process = TopProcess(pid: pid, command: command, usage: usage * Double(1024 * 1024))
                processes.append(process)
            }
        }
        DispatchQueue.main.async(execute: {
            self.processes << processes
        })
    }
    
    @objc func read() {
        var stats = vm_statistics64()
        var count = UInt32(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        
        if kerr == KERN_SUCCESS {
            let active = Float(stats.active_count) * Float(PAGE_SIZE)
//            let inactive = Float(stats.inactive_count) * Float(PAGE_SIZE)
            let wired = Float(stats.wire_count) * Float(PAGE_SIZE)
            let compressed = Float(stats.compressor_page_count) * Float(PAGE_SIZE)
            
            let used = active + wired + compressed
            let free = totalSize - used

            DispatchQueue.main.async(execute: {
                self.usage << MemoryUsage(total: Double(self.totalSize), used: Double(used), free: Double(free))
                self.value << [Double((self.totalSize - free) / self.totalSize)]
            })
        }
        else {
            print("Error with host_statistics64(): " + (String(cString: mach_error_string(kerr), encoding: String.Encoding.ascii) ?? "unknown error"))
        }
    }
    
    func setInterval(value: Int) {
        if value == 0 {
            return
        }
        
        self.updateInterval = value
        self.timer?.reset(.seconds(Double(value)), restart: false)
        self.additionalTimer?.reset(.seconds(Double(value)), restart: false)
    }
}