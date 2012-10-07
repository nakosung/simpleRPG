# REQUIRE
express = require 'express'
http = require 'http'

app = express()
server = http.createServer(app)
io = (require 'socket.io').listen(server)

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

actions =
  'see' : (socket,data,cb) ->
    setActions socket, ['kill','live']
    cb('saw')
  'get' : (socket,data,cb) ->
    cb('got')
  'kill' : (socket,data,cb) ->
    setActions socket, ['see','get']
    cb('killed')
  'live' : (socket,data,cb) ->
    setActions socket, ['see','get']
    cb('lived')

setActions = (socket,actions) ->
  socket.actions = actions
  socket.emit 'actions', socket.actions

gen_map = (n) ->
  r = []
  r.push(0) for x in [1..n]
  r

sendMap = (socket) ->
  n=10
  socket.emit 'map',
    n:n
    map:gen_map(n*n)

setXY = (socket,x,y) ->
  socket.coords = [x,y]
  sendMap socket

# Sockets
io.of('')
  .on 'connection', (socket) ->
    setXY socket, 0, 0
    setActions socket, ['see','get']

    # closure를 이용하여 for loop 문제 회피
    Object.keys(actions).forEach (action) ->
      socket.on action, (data, cb) ->
        actions[action](socket,data,cb)

server.listen 3000, ->
