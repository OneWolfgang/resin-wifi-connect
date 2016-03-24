Promise = require('bluebird')
connman = Promise.promisifyAll(require('connman-simplified')())
express = require('express')
app = express()
bodyParser = require('body-parser')
iptables = Promise.promisifyAll(require('./iptables'))
spawn = require('child_process').spawn
execAsync = Promise.promisify(require('child_process').exec)
os = require('os')
async = require('async')
fs = Promise.promisifyAll(require('fs'))
systemd = require('./systemd')
hostapd = Promise.promisifyAll(require('wireless-tools/hostapd'))
udhcpd = Promise.promisifyAll(require('wireless-tools/udhcpd'))

config = require('./wifi.json')
ssid = process.env.PORTAL_SSID or config.ssid
passphrase = process.env.PORTAL_PASSPHRASE or config.passphrase
port = process.env.PORTAL_PORT or config.port

server = null
ssidList = null
dnsServer = null

connectionFile = '/data/connection.json'

ignore = ->

getIptablesRules = (callback) ->
	async.retry {times: 100, interval: 100}, (cb) ->
		Promise.try ->
			os.networkInterfaces().wlan0[0].address
		.nodeify(cb)
	, (err, myIP) ->
		return callback(err) if err?
		callback null, [
				table: 'nat'
				rule: 'PREROUTING -i wlan0 -j TETHER'
			,
				table: 'nat'
				rule: "TETHER -p tcp --dport 80 -j DNAT --to-destination #{myIP}:#{port}"
			,
				table: 'nat'
				rule: "TETHER -p tcp --dport 443 -j DNAT --to-destination #{myIP}:#{port}"
			,
				table: 'nat'
				rule: "TETHER -p udp --dport 53 -j DNAT --to-destination #{myIP}:53"
		]

setupHostapd = (ssid, passphrase) ->
	options = {
		interface: 'wlan0'
		channel: 1
		driver: 'nl80211'
		hw_mode: 'g'
		ssid: ssid
	}
	if passphrase?
		options.wpa = 2
		options.wpa_passphrase = passphrase

	hostapd.enableAsync(options)

setupUdhcpd = ->
	options = {
		interface: 'wlan0',
		start: '192.168.42.100',
		end: '192.168.42.200',
		option: {
			router: '192.168.42.1',
			subnet: '255.255.255.0',
			dns: [ '192.168.42.1' ]
		}
	}
	execAsync('ifconfig wlan0 192.168.42.1 up')
	.then ->
		udhcpd.enableAsync(options)


openHotspot = (wifi, ssid, passphrase) ->	
	systemd.stop('wpa_supplicant')
	.delay(3000)
	.then ->
		console.log("Opening hotspot")
		setupHostapd(ssid, passphrase)
	.delay(3000)
	.then ->
		setupUdhcpd()
	.catch (err) ->
		console.log(err)

closeHotspot = (wifi) ->
	console.log("Closing hotspot")
	udhcpd.disableAsync('wlan0')
	.then ->
		hostapd.disableAsync('wlan0')

connectOrStartServer = (wifi, retryCallback) ->
	fs.exists connectionFile, (exists) ->
		if exists
			conn = require(connectionFile)
			wifi.joinAsync(conn.ssid, conn.passphrase)
			.then ->
				console.log('Joined! Exiting.')
				retryCallback()
			.catch ->
				startServer(wifi)
		else
			startServer(wifi)

startServer = (wifi) ->
	console.log('Getting networks list')
	wifi.getNetworksAsync()
	.then (list) ->
		ssidList = list
		openHotspot(wifi, ssid, passphrase)
	.then ->
		console.log('Hotspot enabled')
		dnsServer = spawn('named', ['-f'])
		getIptablesRules (err, iptablesRules) ->
			throw err if err?
			iptables.appendManyAsync(iptablesRules)
			.then ->
				console.log('Captive portal enabled')
				server = app.listen port, (err) ->
					throw err if err?
					console.log('Server listening')

console.log('Starting node connman app')
manageConnection = (retryCallback) ->
	connman.initAsync()
	.then ->
		console.log('Connman initialized')
		connman.initWiFiAsync()
	.spread (wifi, properties) ->
		wifi = Promise.promisifyAll(wifi)
		console.log('WiFi initialized')

		app.use(bodyParser())
		app.use(express.static(__dirname + '/public'))
		app.get '/ssids', (req, res) ->
			res.send(ssidList)
		app.post '/connect', (req, res) ->
			if not (req.body.ssid? and req.body.passphrase?)
				return res.sendStatus(400)
			console.log('Selected ' + req.body.ssid)
			res.send('OK')
			server.close()
			closeHotspot(wifi)
			.then ->
				iptables.deleteAsync({ table: 'nat', rule: 'PREROUTING -i wlan0 -j TETHER'})
			.catch(ignore)
			.then ->
				iptables.flushAsync('nat', 'TETHER')
			.catch(ignore)
			.then ->
				dnsServer.kill()
				console.log('Server closed and captive portal disabled')
				fs.writeFileAsync(connectionFile, JSON.stringify({ssid: req.body.ssid, passphrase: req.body.passphrase}))
			.then ->
				console.log('Rebooting')
				systemd.reboot()

		app.use (req, res) ->
			res.redirect('/')

		# Create TETHER iptables chain (will silently fail if it already exists)
		iptables.createChainAsync('nat', 'TETHER')
		.catch(ignore)
		.then ->
			iptables.deleteAsync({ table: 'nat', rule: 'PREROUTING -i wlan0 -j TETHER'})
		.catch(ignore)
		.then ->
			iptables.flushAsync('nat', 'TETHER')
		.then ->
			if !properties.connected
				console.log('Trying to join wifi')
				wifi.joinFavoriteAsync()
				.then ->
					console.log('Joined! Exiting.')
					retryCallback()
				.catch (err) ->
					connectOrStartServer(wifi, retryCallback)
			else
				console.log('Already connected')
				retryCallback()
	.catch (err) ->
		console.log(err)
		return retryCallback(err)

async.retry {times: 10, interval: 1000}, manageConnection, (err) ->
	throw err if err?
	process.exit()
