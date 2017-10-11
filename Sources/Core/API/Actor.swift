/**
 *  Imagine Engine
 *  Copyright (c) John Sundell 2017
 *  See LICENSE file for license
 */

import Foundation

/**
 *  Class used to define an actor in a scene
 *
 *  Actors are used to create active, animatable game objects that will make up
 *  all moving & controllable objects in your game.
 *
 *  This class cannot be subclassed, and is instead designed to be configured &
 *  customized using Imagine Engine's Event & Plugin systems. By accessing an
 *  actor's event collection through the `event` property, you can easily bind
 *  actions to events that occur to it. You can also attach plugins to inject
 *  your own logic into an actor. See `Plugin` for more information.
 *
 *  An example of adding an Actor that is playing an "Idle" animation to a Scene:
 *
 *  ```
 *  let actor = Actor()
 *  actor.animation = Animation(name: "Idle", frameCount: 4, frameDuration: 0.15)
 *  scene.add(actor)
 *  ```
 */
public final class Actor: InstanceHashable, ActionPerformer, Activatable, Movable, Rotatable, Scalable, Fadeable {
    /// The scene that the actor currently belongs to.
    public internal(set) weak var scene: Scene? { didSet { sceneDidChange() } }
    /// A collection of events that can be used to observe the actor.
    public private(set) lazy var events = ActorEventCollection(object: self)
    /// The index of the actor on the z axis. Affects rendering & hit testing. 0 = implicit index.
    public var zIndex = 0 { didSet { layer.zPosition = Metric(zIndex) } }
    /// The position (center-point) of the actor within its scene.
    public var position = Point() { didSet { positionDidChange(from: oldValue) } }
    /// The size of the actor (centered on its position).
    public var size = Size() { didSet { sizeDidChange(from: oldValue) } }
    /// The rectangle the actor currently occupies within its scene.
    public var rect: Rect { return layer.frame }
    /// The rotation of the actor along the z axis.
    public var rotation = Metric() { didSet { layer.rotation = rotation } }
    /// The scale of the actor. Does not affect its size, rect or collision detection.
    public var scale: Metric = 1 { didSet { layer.scale = scale } }
    /// The velocity of the actor. Used for continous directional movement.
    public var velocity = Vector() { didSet { velocityDidChange(from: oldValue) } }
    /// The opacity of the actor. Ranges from 0 (transparent) - 1 (opaque).
    public var opacity = Metric(1) { didSet { layer.opacity = Float(opacity) } }
    /// Any mirroring to apply when rendering the actor. See `Mirroring` for options.
    public var mirroring = Set<Mirroring>() { didSet { layer.mirroring = mirroring } }
    /// The actor's background color. Default is `.clear` (no background).
    public var backgroundColor = Color.clear { didSet { layer.backgroundColor = backgroundColor.cgColor } }
    /// Any texture-based animation that the actor is playing. See `Animation` for more info.
    public var animation: Animation? { didSet { animationDidChange(from: oldValue) } }
    /// Any prefix that should be prepended to the names of all textures loaded for the actor
    public var textureNamePrefix: String?
    /// Any explicit size of the actor's hitbox (for collision detection). `nil` = the actor's `size`.
    public var hitboxSize: Size?
    /// Whether the actor is able to participate in collisions.
    public var isCollisionDetectionEnabled = true
    /// Whether the actor responds to hit testing.
    public var isHitTestingEnabled = true { didSet { hitTestingStatusDidChange(from: oldValue) } }
    /// Any constraints that are applied to the actor, to restrict how and where it can move.
    public var constraints = Set<Constraint>()
    /// Any logical group that the actor is a part of. Can be used for events & collisions.
    public var group: Group?

    internal let layer = Layer()
    internal lazy var actorsInContact = Set<Actor>()
    internal lazy var gridTiles = Set<Grid.Tile>()
    internal private(set) var isClickable = false
    internal var isWithinScene = false

    private let pluginManager = PluginManager()
    private lazy var actionManager = ActionManager(object: self)
    private var velocityActionToken: ActionToken?
    private var animationActionToken: ActionToken?
    
    // MARK: - Initializer

    /// Initialize an instance of this class
    public init() {}

    // MARK: - ActionPerformer

    @discardableResult public func perform(_ action: Action<Actor>) -> ActionToken {
        return actionManager.add(action)
    }

    // MARK: - Activatable

    internal func activate(in game: Game) {
        pluginManager.activate(in: game)
        actionManager.activate(in: game)
    }

    internal func deactivate() {
        scene = nil
        pluginManager.deactivate()
        actionManager.deactivate()
    }

    // MARK: - Public

    public func add<P: Plugin>(_ plugin: @autoclosure () -> P) where P.Object == Actor {
        pluginManager.add(plugin, for: self)
    }

    public func remove<P: Plugin>(_ plugin: P) where P.Object == Actor {
        pluginManager.remove(plugin, from: self)
    }

    /// Remove this actor from its scene
    public func remove() {
        scene?.remove(self)
    }

    // MARK: - Internal

    internal func render(texture: Texture, scale: Int?, resize: Bool, ignoreNamePrefix: Bool) {
        guard let textureManager = scene?.textureManager else {
            return
        }

        let namePrefix = ignoreNamePrefix ? nil : textureNamePrefix
        let loadedTexture = textureManager.load(texture, namePrefix: namePrefix, scale: scale)

        layer.contents = loadedTexture?.image

        if resize {
            size = loadedTexture?.size ?? .zero
        }
    }

    internal func makeClickable() {
        guard !isClickable else {
            return
        }

        isClickable = true
        scene?.add(ClickPlugin())
    }
    
    // MARK: - Private

    private func sceneDidChange() {
        if isClickable {
            scene?.add(ClickPlugin())
        }
    }

    private func positionDidChange(from oldValue: Point) {
        guard position != oldValue else {
            return
        }
        
        layer.position = position
        events.moved.trigger()
        events.rectChanged.trigger()
        rectDidChange()
    }

    private func sizeDidChange(from oldValue: Size) {
        guard size != oldValue else {
            return
        }

        layer.bounds.size = size
        events.resized.trigger()
        events.rectChanged.trigger()
        rectDidChange()
    }

    private func rectDidChange() {
        guard isCollisionDetectionEnabled || isHitTestingEnabled else {
            return
        }

        scene?.actorRectDidChange(self)
    }

    private func velocityDidChange(from oldValue: Vector) {
        guard velocity != oldValue else {
            return
        }

        events.velocityChanged.trigger()
        velocityActionToken?.cancel()

        guard velocity != .zero else {
            return
        }

        velocityActionToken = perform(RepeatAction(
            action: MoveAction(vector: velocity, duration: 1)
        ))
    }

    private func animationDidChange(from oldValue: Animation?) {
        guard animation != oldValue else {
            return
        }

        animationActionToken?.cancel()

        guard let animation = animation else {
            layer.contents = nil
            return
        }

        let action = AnimationAction(animation: animation, triggeredByActor: true)
        animationActionToken = perform(action)
    }

    private func hitTestingStatusDidChange(from oldValue: Bool) {
        if oldValue == false && isHitTestingEnabled == true {
            rectDidChange()
        }
    }
}

public extension Actor {
    /// Initialize an actor that renders a single image as its animation
    convenience init(image: Image) {
        self.init()
        defer {
            animation = Animation(image: image)
        }
    }

    /// Initialize an actor with a given size
    convenience init(size: Size) {
        self.init()
        defer {
            self.size = size
        }
    }

    /// Makes the actor start playing an animation as an action
    func playAnimation(_ animation: Animation) -> ActionToken {
        return perform(AnimationAction(animation: animation))
    }
}

internal extension Actor {
    var rectForCollisionDetection: Rect {
        if let hitboxSize = hitboxSize {
            return Rect(
                origin: Point(
                    x: position.x - hitboxSize.width / 2,
                    y: position.y - hitboxSize.height / 2
                ),
                size: hitboxSize
            )
        }

        return rect
    }
}
