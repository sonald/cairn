import AppKit

final class Events: @unchecked Sendable {
    let lock = NSLock()
    var rows: [[String:Any]] = []
    var counts: [String:Int] = [:]
    func add(_ name:String, _ value:Any) {
        lock.lock(); defer {lock.unlock()}
        let key = "\(name):main=\(Thread.isMainThread)"
        counts[key,default:0] += 1
        if counts[key]! <= 20 { rows.append(["name":name,"mainThread":Thread.isMainThread,"value":value]) }
    }
    func countSnapshot() -> [String:Int] {lock.lock();defer{lock.unlock()};return counts}
    func snapshot() -> [[String:Any]] {lock.lock();defer{lock.unlock()};return rows}
}

@MainActor final class QueueTextView: NSTextView {
    var draws = 0
    var started: Date?
    var targetOffset = 0
    var firstCorrectDrawMs: Double?
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        draws += 1
        guard let started, firstCorrectDrawMs == nil,
              let manager=textLayoutManager,let content=manager.textContentManager,
              let viewport=manager.textViewportLayoutController.viewportRange else{return}
        let low=content.offset(from:content.documentRange.location,to:viewport.location)
        let high=content.offset(from:content.documentRange.location,to:viewport.endLocation)
        guard low<=targetOffset,high>targetOffset else{return}
        var unwrapped=true, count=0
        manager.enumerateTextLayoutFragments(from:viewport.location,options:[]) {fragment in
            if fragment.rangeInElement.location.compare(viewport.endLocation) != .orderedAscending{return false}
            count += 1
            for row in fragment.textLineFragments.dropLast() {
                let text=row.attributedString.string as NSString
                let end=NSMaxRange(row.characterRange)
                if end>0, end<=text.length, text.character(at:end-1) != 10 {unwrapped=false}
            }
            return true
        }
        if count>0,unwrapped {firstCorrectDrawMs=Date().timeIntervalSince(started)*1000}
    }
}

@main struct Main {
    @MainActor static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let source=try String(contentsOfFile:"/Users/siancao/work/ai/vibecoding/codeinsight/fixtures/wrap/f1-ordinary.rs",encoding:.utf8)
        let string=source as NSString
        var lineStarts=[0]
        for i in 0..<string.length where string.character(at:i)==10 {lineStarts.append(i+1)}
        let targetLine=Int(CommandLine.arguments[1])!
        let queue=OperationQueue();queue.name="LigatureQueueProbe";queue.maxConcurrentOperationCount=1
        let events=Events()
        let window=NSWindow(contentRect:NSRect(x:40,y:40,width:560,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:560,height:400));scroll.hasVerticalScroller=true
        let view=QueueTextView(usingTextLayoutManager:true)
        view.isEditable=false;view.isSelectable=true;view.isVerticallyResizable=true;view.isHorizontallyResizable=false
        view.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero;view.textContainerInset=NSSize(width:10,height:12)
        view.autoresizingMask=[.width];view.frame=scroll.contentView.bounds
        view.textContainer!.widthTracksTextView=true
        view.textContainer!.containerSize=NSSize(width:560,height:CGFloat.greatestFiniteMagnitude)
        scroll.documentView=view;window.contentView=scroll
        let manager=view.textLayoutManager!,content=view.textContentStorage!,controller=manager.textViewportLayoutController
        let style=NSMutableParagraphStyle();style.lineHeightMultiple=1.3
        content.performEditingTransaction {view.textStorage!.setAttributedString(NSAttributedString(string:source,attributes:[.font:NSFont(name:"FiraCodeRoman-Regular",size:13)!, .ligature:1,.paragraphStyle:style]))}
        window.orderFront(nil)
        func pump(){RunLoop.current.run(until:Date(timeIntervalSinceNow:0.03));controller.layoutViewport();view.needsDisplay=true;window.displayIfNeeded()}
        for _ in 0..<3{pump()}
        let target=content.location(content.documentRange.location,offsetBy:lineStarts[targetLine-1])!
        for _ in 0..<2 {
            let y=controller.relocateViewport(to:target)
            scroll.contentView.scroll(to:NSPoint(x:0,y:y));scroll.reflectScrolledClipView(scroll.contentView)
            for _ in 0..<3{pump()}
        }
        let beforeHeight=view.frame.height,beforeWidth=view.frame.width
        let delegateBefore=String(describing:controller.delegate)
        let usageObservation=manager.observe(\.usageBoundsForTextContainer,options:[.new]) {_,change in events.add("usageBounds",NSStringFromRect(change.newValue ?? .zero))}
        let queueObservation=queue.observe(\.operationCount,options:[.initial,.new]) {_,change in events.add("operations",change.newValue ?? -1)}
        let started=Date();view.started=started;view.targetOffset=lineStarts[targetLine-1]
        var stages:[String:Double]=[:]
        func mark(_ name:String){stages[name]=Date().timeIntervalSince(started)*1000}
        manager.layoutQueue=queue
        mark("queueAssigned")
        scroll.hasHorizontalScroller=true;view.isHorizontallyResizable=true;view.autoresizingMask.remove(.width)
        view.textContainer!.widthTracksTextView=false
        view.textContainer!.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        mark("containerChanged")
        let firstY=controller.relocateViewport(to:target);mark("firstRelocate")
        let usage=manager.usageBoundsForTextContainer
        if !usage.isEmpty {view.setFrameSize(NSSize(width:max(560,usage.maxX+20),height:max(400,usage.maxY+24)))}
        scroll.tile();scroll.contentView.scroll(to:NSPoint(x:0,y:firstY));scroll.reflectScrolledClipView(scroll.contentView)
        mark("resizedAndScrolled")
        var maxPumpMs=0.0, stableCount=0, previous="",stableMs:Double?
        for iteration in 0..<60 {
            let tick=Date();pump();maxPumpMs=max(maxPumpMs,Date().timeIntervalSince(tick)*1000)
            if iteration==2 {
                let secondY=controller.relocateViewport(to:target)
                scroll.contentView.scroll(to:NSPoint(x:0,y:secondY));scroll.reflectScrolledClipView(scroll.contentView)
            }
            let geometry=NSStringFromRect(view.frame)+NSStringFromRect(scroll.contentView.bounds)+NSStringFromRect(manager.usageBoundsForTextContainer)
            if geometry==previous,view.firstCorrectDrawMs != nil {stableCount+=1}else{stableCount=0}
            previous=geometry
            if stableCount>=5,queue.operationCount==0 {stableMs=Date().timeIntervalSince(started)*1000;break}
        }
        let range=controller.viewportRange
        let low=range.map{content.offset(from:content.documentRange.location,to:$0.location)} ?? -1
        let high=range.map{content.offset(from:content.documentRange.location,to:$0.endLocation)} ?? -1
        var result:[String:Any]=["targetLine":targetLine,"stagesMs":stages,"maxMainPumpMs":maxPumpMs,"beforeFrame":[beforeWidth,beforeHeight],"afterFrame":NSStringFromRect(view.frame),"clip":NSStringFromRect(scroll.contentView.bounds),"usage":NSStringFromRect(manager.usageBoundsForTextContainer),"viewportUTF16":[low,high],"containsTarget":low<=lineStarts[targetLine-1] && high>lineStarts[targetLine-1],"draws":view.draws,"defaultViewportDelegate":delegateBefore,"operationsAtClose":queue.operationCount]
        result["firstCorrectDrawMs"]=view.firstCorrectDrawMs ?? -1
        result["stableMs"]=stableMs ?? -1
        window.close()
        for _ in 0..<20 {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.05))}
        result["operationsOneSecondAfterClose"]=queue.operationCount
        result["callbacks"]=events.snapshot()
        result["callbackCounts"]=events.countSnapshot()
        let data=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]);print(String(decoding:data,as:UTF8.self))
        withExtendedLifetime((usageObservation,queueObservation)){}
        manager.layoutQueue=nil;queue.cancelAllOperations()
    }
}
