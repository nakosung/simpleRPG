# REQUIRE
express = require 'express'
http = require 'http'
EventEmitter = (require 'events').EventEmitter
Q = require 'q'
kdTree = (require './externals/kdtree/src/node/kdTree').kdTree

app = express()
server = http.createServer(app)
io = (require 'socket.io').listen(server, {log:false})

# Configuration

app.configure ->
  app.set('views', __dirname + '/views')
  app.engine 'html', require('ejs').renderFile

  app.get '/', (req,res) ->
    res.render "index.html"
  app.get '/images/'

#  app.use(express.bodyParser())
#  app.use(express.methodOverride())
app.use(express.static(__dirname + '/public'))

app.configure 'development', ->
  app.use(express.errorHandler({ dumpExceptions: true, showStack: true }))


app.configure 'production', ->
  app.use(express.errorHandler())

class Actor
  constructor: (@world, @id, @size=0) ->
    @x = @y = 0
    @updated = 0
    @tickFrequency = -1
    @remainingMilliseconds = 0

  name: ->
    'Actor'

  destroy: ->
    @world.removeActor(this)

  isRelevant: ->
    false

  tick: ->
    #console.log "tick #{@name()}"

  getDiff: (last) ->
    snapshot = @getSnapshot()
    diff = (data,prev) ->
      # nothing changed
      return undefined if data == prev

      # everything changed
      return data if prev == undefined or data.version != prev.version

      result = undefined
      for k, v of data
        if typeof(v) == 'object'
          d = diff(v,prev[k])
          if d
            result ?= {}
            result[k] = d
        else if v != prev[k]
          result ?= {}
          result[k] = data[k]
      result

    difference = diff(snapshot,last?.snapshot)
    {diff:difference,snapshot:snapshot}

class World
  constructor: (@size) ->
    distance = (a,b) ->
      dx = a.x - b.x
      dy = a.y - b.y
      return dx*dx + dy*dy

    @actorsInKdtree = 0
    @kdtree = new kdTree([],distance,["x","y"])
    @actors = {}
    @next_id = 0

  spawn: (klass) ->
    actor = new klass(this,@next_id++)
    @actors[actor.id] = actor
    actor

  removeActor: (actor) ->
    if actor.placed
      @kdtree.remove(actor)
      actor.placed = false
      @actorsInKdtree--
    delete @actors[actor.id]

  tick: (milliseconds) ->
    for k,v of @actors
      if v.tickFrequency > 0
        v.remainingMilliseconds -= milliseconds
        if v.remainingMilliseconds < 0
          v.tick()
          v.remainingMilliseconds = v.tickFrequency

  move: (actor,dx,dy) ->
    x = actor.x + dx
    y = actor.y + dy
    size = actor.size
    collides = (x1,x2,y1,y2) ->
      not (x2 <= y1 or y2 <= x1)

    if @actorsInKdtree > 0
      dist = size * 2
      collided = false
      @kdtree.nearest(actor,100,dist * dist).forEach (i) ->
        v = i[0]
        if v != actor and collides(x,x+size,v.x,v.x+size) and collides(y,y+size,v.y,v.y+size)
          collided = true
          return false
      if collided
        return false

    if actor.placed
      @kdtree.remove(actor)
    else
      @actorsInKdtree++

    actor.placed = true
    @kdtree.insert(actor)

    actor.x = x
    actor.y = y
    true

class Map extends Actor
  init: (size) ->
    @size = size
    @version = 0
    gen_map = (n) ->
      r = []
      r.push(0) for x in [1..n]
      r
    @data = gen_map(@size*@size)
  getSnapshot: ->
    size:@size
    data:@data
    version:@version
  name: ->
    "Map"
  isRelevant: ->
    true
  modify: (x,y,c) ->
    x = Math.floor(x)
    y = Math.floor(y)
    @data[x + y * @size] = c
    @version++



world = new World(10)
world.map = world.spawn(Map)
world.map.init(10)

class Building extends Actor
  init: ->

  name: ->
    "Building"

  getSnapshot: ->
    x:@x
    y:@y
    img:@img


class Pawn extends Actor
  init: (@type = 2, @tickFrequency = 20) ->
    @size = 1
    @dx = @dy = 0
    @dir = 'stop'
    @chat 'hello'
    @promises = []

    dx = 0
    while not (@world.move this, dx, 0)
      dx++

  tick: ->
    @check 'tick', (p) ->
      return --p.data <= 0

    if not (world.move this, @dx, @dy)
      @move 'stop'

    if @chat_ttl > 0 and --@chat_ttl == 0
      @chat_msg = ''

    super

  move: (dir,cb) ->
    if @dir != dir
      @dir = dir
      @check dir
      map =
        moveLeft:[-1,0]
        moveRight:[1,0]
        moveUp:[0,-1]
        moveDown:[0,1]
        stop:[0,0]
      delta = map[dir]
      if delta
        @dx = delta[0] / 4.0
        @dy = delta[1] / 4.0
      else
        @dx = @dy = 0
    cb?()

  chat: (msg) ->
    @chat_ttl = 10
    @chat_msg = msg

  when: (cond,data) ->
    d = Q.defer()
    @promises[cond] ?=
      data:data
      promises:[]
    @promises[cond].promises.push(d)
    d.promise

  check: (cond,fn) ->
    p = @promises[cond]
    if p and (fn == undefined or fn(p))
      for v,k in p.promises
        v.resolve()
      delete @promises[cond]

  name: ->
    "Pawn"

  isRelevant: ->
    true

  getSnapshot: ->
    x:@x
    y:@y
    dir:@dir
    chat:@chat_msg
    type:@type

class Channel
  constructor: (@socket,@maxActors=10,@maxDist=10) ->
    @hash = {}

  destroy: ->

  getRelavantActors: (controller) ->
    pawn = controller.pawn

    for k,v of @hash
      v.mark++

    potentialRelavantActors = world.kdtree.nearest(pawn,@maxActors,@maxDist * @maxDist).map (x) ->
      x[0]
    potentialRelavantActors.push(world.map)
    potentialRelavantActors.push(pawn)
    potentialRelavantActors.push(controller)

    for v in potentialRelavantActors
      k = v.id
      if v.isRelevant(controller)
        x = @hash[k]
        if x == undefined
          x = @hash[k] =
            actor:v
            mark: 0
            ttl: 10
        x.mark = 0

    for k,v of @hash
      if v.mark > v.ttl
        v.pendingKill = true

  send: ->
    bunch = []
    for k,v of @hash
      try
        if v.pendingKill
          bunch.push
            nid: k
            deleted: true
          delete @hash[k]
        else
          isFirstTime = v.last == undefined
          v.last = v.actor.getDiff v.last
          if v.last.diff
            if isFirstTime
              bunch.push
                nid: k
                name: v.actor.name()
                data: v.last.diff
            else
              bunch.push
                nid: k
                data: v.last.diff
      catch e
        console.warn 'send got error', e, k

    @socket.emit 'data', bunch if bunch.length

class Controller extends Actor
  getPawnClass: ->
    Pawn

  isRelevant: (controller) ->
    controller == this

  init : () ->
    @tickFrequency = 20
    @pawn = world.spawn @getPawnClass()
    @pawn.init()

    @setActions(['get','see'])

  destroy: ->
    clearTimeout @timer
    @pawn.destroy()
    @channel.destroy()
    super

  name: ->
    'Controller'

  setActions : (actions) ->
    @actions = actions
    @sendActions()

  sendActions: ->


  actionHandler : (action,data,callback) ->
    f = this[action]
    if typeof(f) == 'function'
      f(data,callback)
    else
      console.warn("unhandled action #{action}")

  get : (d,c) =>
    @setActions ['run','kill']
    c?()

  see : (d,c) =>
    @setActions ['hide','see']
    c?()

  hide : (d,c) =>
    @setActions ['hide','run']
    c?()

  run : (d,c) =>
    @setActions ['kill','hide']
    c?()

  map : (d,c) =>
    @world.map.modify @pawn.x, @pawn.y, d

  move : (d,c) =>
    @pawn.move(d,c)

  stop : (d,c) =>
    @move([0,0],c)

  getSnapshot: ->
    pawn: @pawn.id

class PlayerController extends Controller
  init : (@socket) ->
    super

    @channel = new Channel(@socket)

    @socket.on 'action', (data,callback) =>
      @actionHandler(data.action,data.data,callback)
    @socket.on 'chat', (data,callback) =>
      @pawn.chat data
      callback?()

  tick: ->
    @channel.getRelavantActors(this)
    @channel.send()
    super

  sendActions: ->
    @socket.emit 'actions', @actions

# Sockets
io.of('')
  .on 'connection', (socket) ->
    socket.controller = world.spawn PlayerController
    socket.controller.init socket
    socket.on 'disconnect', ->
      socket.controller.destroy()

class AIController extends Controller
  init: ->
    super

    right = =>
      @pawn.move 'moveRight'
      @pawn.chat '오른쪽'
      @pawn.when('tick',10).then =>
        @pawn.move 'moveLeft'
        @pawn.chat '왼쪽'
        @pawn.when('tick',10).then =>
          right()

    right()

  tick: ->


aic = world.spawn AIController
aic.init()
aic.pawn.type = 0


milliseconds = 20
tick = () ->
  world.tick milliseconds
  setTimeout tick, milliseconds

tick()

server.listen 3000, ->
