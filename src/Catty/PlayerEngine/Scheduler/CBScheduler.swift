/**
 *  Copyright (C) 2010-2017 The Catrobat Team
 *  (http://developer.catrobat.org/credits)
 *
 *  This program is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License as
 *  published by the Free Software Foundation, either version 3 of the
 *  License, or (at your option) any later version.
 *
 *  An additional term exception under section 7 of the GNU Affero
 *  General Public License, version 3, is available at
 *  (http://developer.catrobat.org/license_additional_term)
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with this program.  If not, see http://www.gnu.org/licenses/.
 */

final class CBScheduler: CBSchedulerProtocol {
    
    // MARK: - Properties
    var logger: CBLogger
    //    var schedulingAlgorithm: CBSchedulingAlgorithmProtocol?
    var running = false
    private let _broadcastHandler: CBBroadcastHandlerProtocol
    
    private var _spriteNodes = [String:CBSpriteNode]()
    private var _contexts = [CBScriptContextProtocol]()
    private var _whenContexts = [String:[CBWhenScriptContext]]()
    private var _scheduledContexts = OrderedDictionary<String,[CBScriptContextProtocol]>()
    private var _contextsWaitingToBeScheduled = OrderedDictionary<String,[CBScriptContextProtocol]>()
    private var _hasNewBroadcastContextBeenScheduled = false
    
    private var _availableWaitQueues = [DispatchQueue]()
    private var _availableBufferQueues = [DispatchQueue]()
    private let _lockWaitQueue = DispatchQueue(label: "org.catrobat.LockWaitQueue", attributes: [])
    private let _lockBufferQueue = DispatchQueue(label: "org.catrobat.LockBufferQueue", attributes: [])
    private var _lastQueueIndex = 0
    
    // MARK: Static properties
    static let vibrateSerialQueue = OperationQueue()
    
    // MARK: - Initializers
    init(logger: CBLogger, broadcastHandler: CBBroadcastHandlerProtocol) {
        self.logger = logger
        //        self.schedulingAlgorithm = nil // default scheduling behaviour
        _broadcastHandler = broadcastHandler
    }
    
    // MARK: - Queries
    func isContextScheduled(_ context: CBScriptContextProtocol) -> Bool {
        guard let spriteName = context.spriteNode.name
            else { fatalError("Sprite node has no name!") }
        return _scheduledContexts[spriteName]?.contains(context) == true
    }
    
    // MARK: - Model methods
    func registerSpriteNode(_ spriteNode: CBSpriteNode) {
        precondition(spriteNode.name != nil)
        precondition(_spriteNodes[spriteNode.name!] == nil)
        _spriteNodes[spriteNode.name!] = spriteNode
    }
    
    func registerContext(_ context: CBScriptContextProtocol) {
        guard let spriteName = context.spriteNode.name else { fatalError("Sprite node has no name!") }
        precondition(!_contexts.contains(context))
        precondition(_spriteNodes[spriteName] == context.spriteNode)
        
        if context is CBWhenScriptContext {
            _contexts.insert(context, at: 0);
        } else {
            _contexts += context
        }
        if let whenContext = context as? CBWhenScriptContext {
            if _whenContexts[spriteName] == nil {
                _whenContexts[spriteName] = [CBWhenScriptContext]()
            }
            _whenContexts[spriteName]! += whenContext
        }
    }
    
    // MARK: - Scheduling
    func runNextInstructionOfContext(_ context: CBScriptContextProtocol) {
        assert(Thread.current.isMainThread)
        context.state = .runnable
        runNextInstructionsGroup()
    }
    
    // <<<<<<<<<<<<<<<<<<|>>>>>>>>>>>>>>>>>>
    // <<<   SCHEDULER   |   CONTROLLER  >>>
    // <<<<<<<<<<<<<<<<<<|>>>>>>>>>>>>>>>>>>
    func runNextInstructionsGroup() {
        guard self.running else { return }
        // TODO: apply scheduling via StrategyPattern => selects scripts to be scheduled NOW!
        assert(Thread.current.isMainThread)
        
        var nextHighPriorityClosures = [CBHighPriorityScheduleElement]()
        var nextClosures = [CBScheduleElement]()
        var nextWaitClosures = [CBScheduleElement]()
        var nextBufferElements = [CBFormulaBufferElement]()
        var nextConditionalBufferElements = [CBConditionalFormulaBufferElement]()
        for (spriteName, contexts) in _scheduledContexts {
            guard let spriteNode = _spriteNodes[spriteName]
                else { fatalError("WTH?? Sprite node not available (any more)...") }
            
            // collect
            var nextLongActionElements = [CBScheduleLongActionElement]()
            var nextActionElements = [CBScheduleActionElement]()
            var hasRunnableContexts = false
            for context in contexts {
                
                if context.state != .runnable { continue }
                context.state = .running
                if let nextInstruction = context.nextInstruction() {
                    switch nextInstruction {
                    case let .highPriorityExecClosure(closure):
                        nextHighPriorityClosures += (context, closure)
                    case let .execClosure(closure):
                        nextClosures += (context, closure)
                    case let .longDurationAction(durationFormula, actionCreateClosure):
                        nextLongActionElements += (context, durationFormula, actionCreateClosure)
                    case let .waitExecClosure(closure):
                        nextWaitClosures += (context, closure)
                    case let .action(action):
                        nextActionElements += (context, action)
                    case let .formulaBuffer(brick):
                        nextBufferElements += (context, brick)
                    case let .conditionalFormulaBuffer(condition):
                        nextConditionalBufferElements += (context, condition)
                    case .invalidInstruction:
                        context.state = .runnable
                        continue // skip invalid instruction
                    }
                } else {
                    stopContext(context, continueWaitingBroadcastSenders: true)
                    logger.debug("All actions/instructions have been finished!")
                }
                hasRunnableContexts = true;
            }
            
            // execute actions (node dependend!)
            if nextActionElements.count > 0 {
                let groupAction = nextActionElements.count > 1
                    ? SKAction.group(nextActionElements.map { $0.action })
                    : nextActionElements.first!.1
                spriteNode.run(groupAction, completion: { [weak self] in
                    nextActionElements.forEach { $0.context.state = .runnable }
                    self?.runNextInstructionsGroup()
                    self?.scheduleBroadcastContext(spriteName, checkForOtherContexts: true)
                    while self?._hasNewBroadcastContextBeenScheduled == true {
                        self?._hasNewBroadcastContextBeenScheduled = false;
                        self?.runNextInstructionsGroup()
                    }
                })
            }
            
            for (context, duration, actionCreateClosure) in nextLongActionElements {
                var durationTime = 0.0
                switch duration {
                case let .varTime(formula):
                    durationTime = formula.interpretDouble(forSprite: context.spriteNode.spriteObject)
                case let .fixedTime(time):
                    durationTime = time
                }
                let action = actionCreateClosure(durationTime)
                spriteNode.run(action, completion: { [weak self] in
                    context.state = .runnable
                    self?.runNextInstructionsGroup()
                    self?.scheduleBroadcastContext(spriteName, checkForOtherContexts: true)
                    while self?._hasNewBroadcastContextBeenScheduled == true {
                        self?._hasNewBroadcastContextBeenScheduled = false;
                        self?.runNextInstructionsGroup()
                    }
                }) 
            }
            
            // Schedule contexts that do not have to wait for an action to be completed earlier
            if nextActionElements.count == 0 && nextLongActionElements.count == 0 && hasRunnableContexts {
                scheduleBroadcastContext(spriteName, checkForOtherContexts: false)
            }
        }
        
        // execute closures (not node dependend!)
        
        for (context, closure) in nextWaitClosures {
            self._lockWaitQueue.async {
                var queue = self._availableWaitQueues.first
                if queue == nil {
                    self._lastQueueIndex += 1
                    queue = DispatchQueue(label: "org.catrobat.wait.queue[\(self._lastQueueIndex)]", attributes: [])
                } else {
                    self._availableWaitQueues.removeFirst()
                }
                queue!.async(execute: {
                    let index = context.index
                    closure(context, self)
                    self._lockWaitQueue.async {
                        self._availableWaitQueues += queue!
                    }
                    if index == context.index {
                        DispatchQueue.main.async {
                            self.runNextInstructionOfContext(context)
                        }
                    }
                })
            }
        }
        
        for (context, closure) in nextClosures {
            closure(context, self)
        }
        
        for (context, brick) in nextBufferElements {
            self._lockBufferQueue.async {
                var queue = self._availableBufferQueues.first
                if queue == nil {
                    queue = DispatchQueue.global(qos: DispatchQoS.QoSClass.default)
                } else {
                    self._availableBufferQueues.removeFirst()
                }
                queue!.async(execute: {
                    let index = context.index
                    let formulaArray = brick.getFormulas()
                    for formula:Formula in formulaArray! {
                        formula.preCalculate(forSprite: context.spriteNode.spriteObject)
                    }
                    print("preCalculate")
                    self._lockBufferQueue.async {
                        self._availableBufferQueues += queue!
                    }
                    if index == context.index {
                        DispatchQueue.main.async {
                            self.runNextInstructionOfContext(context)
                        }
                    }
                })
            }
        }
        
        for (context, condition) in nextConditionalBufferElements {
            self._lockBufferQueue.async {
                var queue = self._availableBufferQueues.first
                if queue == nil {
                    queue = DispatchQueue.global(qos: DispatchQoS.QoSClass.default)
                } else {
                    self._availableBufferQueues.removeFirst()
                }
                queue!.async(execute: {
                    let index = context.index
                    condition.bufferCondition(context.spriteNode.spriteObject)
                    self._lockBufferQueue.async {
                        self._availableBufferQueues += queue!
                    }
                    if index == context.index {
                        DispatchQueue.main.async {
                            self.runNextInstructionOfContext(context)
                        }
                    }
                })
            }
        }
        
        if nextClosures.count > 0 && nextHighPriorityClosures.count == 0 {
            runNextInstructionsGroup()
            return
        }
        
        for (context, closure) in nextHighPriorityClosures {
            closure(context, self, _broadcastHandler)
        }
    }
    
    // MARK: - Events
    func run() {
        assert(!running)
        logger.info(">>> [SCHEDULER STARTED] <<<")
        running = true
        _broadcastHandler.setup()
        
        for idx in 1 ... PlayerConfig.NumberOfWaitQueuesInitialValue {
            _availableWaitQueues += DispatchQueue(label: "org.catrobat.wait.queue[\(idx)]", attributes: [])
        }
        _lastQueueIndex = PlayerConfig.NumberOfWaitQueuesInitialValue
        
        // schedule all start scripts
        _contexts.forEach { if $0 is CBStartScriptContext { scheduleContext($0) } }
        // ... Ready...Steady...Gooooo!! => invoke first instruction!
        runNextInstructionsGroup()
        while _hasNewBroadcastContextBeenScheduled {
            _hasNewBroadcastContextBeenScheduled = false
            runNextInstructionsGroup()
        }
    }
    
    func scheduleContext(_ context: CBScriptContextProtocol) {
        guard let spriteName = context.spriteNode.name else { fatalError("Sprite node has no name!") }
        //assert(_contexts.contains(context))
        logger.info("[STARTING: \(context.script)]")
        logger.debug("  >>> !!! RESETTING: \(context.script) <<<")
        context.state = .runnable
        context.reset()
        // if context.hasActions() { context.removeAllActions() }
        
        // enqueue
        // TODO: use Set-datastructure instead...
        if _scheduledContexts[spriteName] == nil {
            _scheduledContexts[spriteName] = [CBScriptContext]()
        }
        if let contexts = _scheduledContexts[spriteName]{
            if !contexts.contains(context) {
                _scheduledContexts[spriteName]! += context
                _hasNewBroadcastContextBeenScheduled = true
            }
        }
    }
    
    func scheduleBroadcastContext(_ spriteName: String, checkForOtherContexts: Bool) {
        if _scheduledContexts[spriteName] == nil {
            _scheduledContexts[spriteName] = [CBScriptContext]()
        }
        if let contextsToSchedule = _contextsWaitingToBeScheduled[spriteName] {
            contextsToSchedule.forEach({_scheduledContexts[spriteName]! += $0})
            _contextsWaitingToBeScheduled.removeValueForKey(spriteName)
            _hasNewBroadcastContextBeenScheduled = true;
        }
        
        if checkForOtherContexts {
            // check for contexts of sprites whose contexts have not been scheduled yet at all
            for name in _contextsWaitingToBeScheduled.orderedKeys {
                if !_scheduledContexts.containsKey(name) || _scheduledContexts[name]!.count == 0 {
                    _scheduledContexts[name] = [CBScriptContext]()
                    _contextsWaitingToBeScheduled[name]?.forEach({_scheduledContexts[name]! += $0})
                    _contextsWaitingToBeScheduled.removeValueForKey(name)
                    _hasNewBroadcastContextBeenScheduled = true;
                }
            }
        }
    }
    
    func putBroadcastContextOnHold(_ context: CBScriptContextProtocol) {
        guard let spriteName = context.spriteNode.name else { fatalError("Sprite node has no name!") }
        //assert(_contexts.contains(context))
        logger.info("[STARTING: \(context.script)]")
        logger.debug("  >>> !!! RESETTING: \(context.script) <<<")
        context.state = .runnable
        context.reset()
        // if context.hasActions() { context.removeAllActions() }
        
        // enqueue
        // TODO: use Set-datastructure instead...
        if _contextsWaitingToBeScheduled[spriteName] == nil {
            _contextsWaitingToBeScheduled[spriteName] = [CBScriptContext]()
        }
        if let contexts = _contextsWaitingToBeScheduled[spriteName]{
            if !contexts.contains(context) {
                _contextsWaitingToBeScheduled[spriteName]! += context
                _hasNewBroadcastContextBeenScheduled = true;
            }
        }
        
    }
    
    func startWhenContextsOfSpriteNodeWithName(_ spriteName: String) {
        guard let contexts = _whenContexts[spriteName] else { return }
        
        for context in contexts {
            scheduleContext(context)
        }
        
        runNextInstructionsGroup()
        while _hasNewBroadcastContextBeenScheduled {
            _hasNewBroadcastContextBeenScheduled = false
            runNextInstructionsGroup()
        }
    }
    
    func startBroadcastContexts(_ broadcastContexts: [CBBroadcastScriptContextProtocol]) {
        
        for context in broadcastContexts {
            if context.state == .running || context.state == .waiting {
                _broadcastHandler.terminateAllCalledBroadcastContextsAndRemoveWaitingContext(context)
            }
            
            putBroadcastContextOnHold(context)
        }
    }
    
    func stopContext(_ context: CBScriptContextProtocol, continueWaitingBroadcastSenders: Bool) {
        guard let spriteName = context.spriteNode.name else { fatalError("Sprite node has no name!") }
        //        assert(!_broadcastHandler.isWaitingForCalledBroadcastContexts(context))
        if context.state == .dead { return } // already stopped => must be an old deprecated dispatch closure
        let script = context.script
        logger.info("!!! STOPPING: \(script)")
        
        context.state = .dead
        
        if let broadcastContext = context as? CBBroadcastScriptContext, continueWaitingBroadcastSenders {
            _broadcastHandler.wakeUpContextsWaitingForTerminationOfBroadcastContext(broadcastContext)
        }
        
        // dequeue
        var spriteScheduledContexts = _scheduledContexts[spriteName]!
        if let index = spriteScheduledContexts.indexOfElement(context) {
            spriteScheduledContexts.remove(at: index)
        }
        
        if spriteScheduledContexts.count > 0 {
            _scheduledContexts[spriteName] = spriteScheduledContexts
        } else {
            _scheduledContexts[spriteName] = [CBScriptContext]()
        }
        
        logger.debug("\(script) finished!")
    }
    
    func shutdown() {
        logger.info("!!! SCHEDULER SHUTDOWN !!!")
        CBScheduler.vibrateSerialQueue.cancelAllOperations()
        CBScheduler.vibrateSerialQueue.isSuspended = false
        
        _scheduledContexts.orderedValues.forEach { $0.forEach {
            stopContext($0, continueWaitingBroadcastSenders: false)
            } }
        _scheduledContexts.removeAll()
        _whenContexts.removeAll()
        _contexts.removeAll()
        _broadcastHandler.tearDown()
        running = false
    }
    
    func pause() {
        running = false
        CBScheduler.vibrateSerialQueue.isSuspended = true
    }
    
    func resume() {
        if(running == false){
            running = true
            runNextInstructionsGroup()
            CBScheduler.vibrateSerialQueue.isSuspended = false
        }
    }
    
}
