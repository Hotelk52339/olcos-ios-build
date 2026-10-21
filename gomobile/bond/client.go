package bond

import (
	"crypto/rand"
	"errors"
	"io"
	"log"
	"net"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// bondOffFor: once the bond server could not be reached through the
	// lanes, connections go plain for this long before bonding is tried again.
	bondOffFor   = time.Minute
	handshakeMax = 30 * time.Second
	// redialMax caps the wait between calls to a lost lane, in redialBases:
	// a lane can be gone for minutes, and a stream must find it soon after
	// it is back.
	redialMax = 16
)

// Timing knobs as variables so the tests can shorten them.
var (
	// subTimeout bounds one lane's CONNECT to the bond server and the hello.
	subTimeout = 20 * time.Second
	// replyWait bounds the bond server's reply once the lane carried the
	// hello: the server dials the target for up to dialTimeout, and its own
	// verdict (unreachable) must get through. A client that gave up sooner
	// took a slow target for a failure of every lane, and benched them all.
	replyWait = dialTimeout + 5*time.Second
	// A lane that failed twice in a row sits out benchFor.
	benchFor = 15 * time.Second
	// redialBase is the first wait before calling a lost lane back.
	redialBase = time.Second
)

var (
	errNoBond  = errors.New("bond: the bond server did not answer")
	errStopped = errors.New("bond: stopped")
)

// Client is the app side. Apps connect to its SOCKS5 listener on loopback.
// Every CONNECT is carried over all lanes at once, one sub-connection per lane
// to the bond server; anything else (UDP ASSOCIATE) goes through one lane as
// it is, and so do CONNECTs while the bond server cannot be reached.
type Client struct {
	listenPort int
	user, pass string
	keyHex     string
	bondAddr   string

	id [8]byte
	// mu guards the fields below and every lane's state. It is held only
	// for a few lines, never across a dial or while a stripe's mu is taken
	// (a stripe calls onLoss after releasing its own).
	mu       sync.Mutex
	key      []byte
	lanes    []*lane
	ln       net.Listener
	open     map[io.Closer]struct{}
	offUntil time.Time
	rr       int
	stopped  bool
	// direct names the destinations served from this process instead of over
	// the lanes (SetDirectRules); nil sends everything through.
	direct *directRules

	bonded  atomic.Int64
	plain   atomic.Int64
	directs atomic.Int64
}

type lane struct {
	port       int
	user, pass string
	failures   int
	benched    time.Time // sits out until then
	stats      *laneStats
	// back is closed (and replaced) when the lane carries again after
	// trouble: the streams waiting to call it back try at once.
	back chan struct{}
	// dropped: a stream lost its sub-connection here since the lane last
	// carried, so whether it still carries is in doubt.
	dropped bool
	// probing: a stream is calling the lane back while it is in trouble;
	// the others wait for the outcome (see claim).
	probing bool
}

// troubled: the lane failed lately, sits out or dropped a stream, and has
// not carried since.
func (l *lane) troubled() bool {
	return l.failures > 0 || !l.benched.IsZero() || l.dropped
}

// NewClient makes a client for apps on 127.0.0.1:listenPort (user empty: no
// login) that bonds over its lanes to the bond server at bondHost:bondPort,
// signing with the tunnel key. Lanes come with AddLane; nothing runs before
// Start.
func NewClient(listenPort int, user, pass, keyHex, bondHost string, bondPort int) *Client {
	c := &Client{
		listenPort: listenPort,
		user:       user,
		pass:       pass,
		keyHex:     keyHex,
		bondAddr:   net.JoinHostPort(bondHost, strconv.Itoa(bondPort)),
		open:       make(map[io.Closer]struct{}),
	}
	_, _ = rand.Read(c.id[:])
	return c
}

// AddLane adds a lane: an olcrtc SOCKS5 listener on 127.0.0.1:socksPort.
func (c *Client) AddLane(socksPort int, user, pass string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lanes = append(c.lanes, &lane{port: socksPort, user: user, pass: pass, stats: &laneStats{},
		back: make(chan struct{})})
}

// Start listens for apps. It fails on a bad key or a port that is taken.
func (c *Client) Start() error {
	key, err := ParseKey(c.keyHex)
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(c.listenPort)))
	if err != nil {
		return err
	}
	c.mu.Lock()
	c.key, c.ln = key, ln
	c.mu.Unlock()
	go c.accept(ln)
	return nil
}

// Stop closes the listener and every connection on it.
func (c *Client) Stop() {
	c.mu.Lock()
	c.stopped = true
	ln := c.ln
	open := make([]io.Closer, 0, len(c.open))
	for x := range c.open {
		open = append(open, x)
	}
	c.open = make(map[io.Closer]struct{})
	c.mu.Unlock()
	if ln != nil {
		_ = ln.Close()
	}
	for _, x := range open {
		_ = x.Close()
	}
}

// Bonded counts the connections carried over every lane at once.
func (c *Client) Bonded() int64 { return c.bonded.Load() }

// Plain counts the connections that went through a single lane.
func (c *Client) Plain() int64 { return c.plain.Load() }

// SetDirectRules names the destinations an app's CONNECT reaches straight
// from this process instead of over the lanes, in the syntax the olcrtc core
// takes: `domain:<name>`, `full:<name>`, an address or a CIDR prefix, one per
// line, # comments. Empty sends everything through the lanes.
func (c *Client) SetDirectRules(text string) {
	rules := parseDirect(text)
	c.mu.Lock()
	c.direct = rules
	c.mu.Unlock()
}

// Direct counts the connections served straight from this process.
func (c *Client) Direct() int64 { return c.directs.Load() }

// LaneBytes is what every lane has carried so far, in the order AddLane
// added them: "rx:tx" per lane, comma-separated, rx toward the app. The app
// samples it to show each lane's speed.
func (c *Client) LaneBytes() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	parts := make([]string, len(c.lanes))
	for i, l := range c.lanes {
		parts[i] = strconv.FormatInt(l.stats.rx.Load(), 10) + ":" + strconv.FormatInt(l.stats.tx.Load(), 10)
	}
	return strings.Join(parts, ",")
}

func (c *Client) accept(ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go c.serve(conn)
	}
}

func (c *Client) serve(app net.Conn) {
	if !c.track(app) {
		_ = app.Close()
		return
	}
	defer c.untrack(app)
	defer app.Close()
	_ = app.SetDeadline(time.Now().Add(handshakeMax))
	req, err := acceptSocks(app, c.user, c.pass)
	if err != nil {
		return
	}
	_ = app.SetDeadline(time.Time{})
	if req.cmd == cmdConnect && c.isDirect(req.target) {
		c.directRelay(app, req)
		return
	}
	if req.cmd == cmdConnect && c.bonding() && c.bond(app, req) {
		return
	}
	c.plainRelay(app, req)
}

func (c *Client) isDirect(target string) bool {
	c.mu.Lock()
	rules := c.direct
	c.mu.Unlock()
	return rules.matchTarget(target)
}

// directRelay serves a listed destination from this process.
func (c *Client) directRelay(app net.Conn, req socksRequest) {
	conn, err := net.DialTimeout("tcp", req.target, subTimeout)
	if err != nil {
		_, _ = app.Write(socksReply(repHostUnreachable))
		return
	}
	if !c.track(conn) {
		_ = conn.Close()
		return
	}
	defer c.untrack(conn)
	if _, err := app.Write(socksReply(repSuccess)); err != nil {
		_ = conn.Close()
		return
	}
	c.directs.Add(1)
	relay(app, conn)
}

type subResult struct {
	lane  int
	conn  net.Conn
	reply byte
	err   error
}

// bond carries one CONNECT over every lane that is up. false: the bond
// server answered on none of them, and the caller goes plain.
func (c *Client) bond(app net.Conn, req socksRequest) bool {
	lanes, total := c.pickLanes()
	var session [16]byte
	if _, err := rand.Read(session[:]); err != nil {
		return false
	}
	results := make(chan subResult, len(lanes))
	for _, i := range lanes {
		go func(i int) {
			conn, reply, err := c.dialSub(i, total, session, req.target, false)
			results <- subResult{lane: i, conn: conn, reply: reply, err: err}
		}(i)
	}
	// A lane whose room is gone parks the CONNECT (the core waits for its
	// session), so a slow answer is not a dead bond server: the connection
	// waits for every lane still on its way, up to the server's reply. Nor is
	// one lane's "cannot reach it": that lane's own session may be gone.
	// Bonding goes off only when every lane has answered so.
	hardStop := time.NewTimer(replyWait + 2*time.Second)
	defer hardStop.Stop()
	left := len(lanes)
	var first *subResult
	unreachable, noBond := false, 0
	// later: the lanes the stream calls back once it runs, those sitting out
	// now and those that fail now.
	var later []int
	for i := 0; i < total; i++ {
		if !slices.Contains(lanes, i) {
			later = append(later, i)
		}
	}
wait:
	for left > 0 {
		select {
		case r := <-results:
			left--
			switch {
			case r.err != nil:
				if errors.Is(r.err, errNoBond) {
					noBond++
				}
				later = append(later, r.lane)
			case r.reply == replyOK:
				first = &r
				break wait
			default:
				unreachable = unreachable || r.reply == replyUnreachable
				_ = r.conn.Close()
			}
		case <-hardStop.C:
			break wait
		}
	}
	if first == nil {
		go closeLate(results, left)
		switch {
		case unreachable:
			_, _ = app.Write(socksReply(repHostUnreachable))
			return true
		case noBond == total:
			c.bondOff()
		}
		return false
	}

	if _, err := app.Write(socksReply(repSuccess)); err != nil {
		// The app is gone before the stream began: told, the server lets
		// the target go at once instead of waiting out its lanes.
		resetAndClose(first.conn)
		go closeLate(results, left)
		return true
	}
	st := newStripe(app)
	st.onLoss = func(lane int) {
		c.laneDropped(lane)
		go c.redial(st, lane, total, session, req.target)
	}
	st.add(first.lane, first.conn, c.statsOf(first.lane))
	for _, i := range later {
		go c.redial(st, i, total, session, req.target)
	}
	go func() {
		for ; left > 0; left-- {
			switch r := <-results; {
			case r.err == nil && r.reply == replyOK:
				st.add(r.lane, r.conn, c.statsOf(r.lane))
			case r.conn != nil:
				_ = r.conn.Close() // the server turned it away: the stream is over there
			default:
				go c.redial(st, r.lane, total, session, req.target)
			}
		}
	}()
	stop := &stripeStop{st}
	if !c.track(stop) {
		st.drop(errStopped)
		return true
	}
	defer c.untrack(stop)
	c.bonded.Add(1)
	_ = st.run()
	return true
}

// dialSub opens one sub-connection through lane i and returns the bond
// server's reply; rejoin marks a call back for a stream already open. The
// lane's SOCKS server reads its handshake byte by byte, so greeting, CONNECT
// and hello go in one write: one round trip over the lane instead of two.
func (c *Client) dialSub(i, total int, session [16]byte, target string, rejoin bool) (net.Conn, byte, error) {
	l, key := c.laneAt(i)
	h := hello{session: session, client: c.id, lane: uint8(i), lanes: uint8(min(total, rejoinFlag-1)),
		rejoin: rejoin, unix: uint64(time.Now().Unix()), target: target}
	hb, err := h.marshal(key)
	if err != nil {
		return nil, 0, err
	}
	connect, err := connectRequest(c.bondAddr)
	if err != nil {
		return nil, 0, err
	}
	conn, err := net.DialTimeout("tcp", laneAddr(l.port), 5*time.Second)
	if err != nil {
		c.laneFailed(i)
		return nil, 0, err
	}
	_ = conn.SetDeadline(time.Now().Add(subTimeout))
	opening := append(append(greeting(l.user, l.pass), connect...), hb...)
	if _, err := conn.Write(opening); err != nil {
		return nil, 0, c.subFailed(i, conn, err)
	}
	if err := readGreetingReply(conn, l.user); err != nil {
		return nil, 0, c.subFailed(i, conn, err)
	}
	if err := readConnectReply(conn); err != nil {
		// The lane is up but its exit could not reach the bond server; "network
		// unreachable" is the lane's own (no tunnel session to park on). So is
		// "host unreachable" when the lane's session is gone (the core answers
		// a parked CONNECT so when its session does not come back), and one
		// lane cannot tell which it is: the lane counts a failure, and the
		// caller weighs the answer against every other lane's.
		var refused socksRefusedError
		if errors.As(err, &refused) && refused.code != repNetUnreachable {
			return nil, 0, errors.Join(errNoBond, c.subFailed(i, conn, err))
		}
		return nil, 0, c.subFailed(i, conn, err)
	}
	// The lane carried the hello; from here the wait is the server's.
	_ = conn.SetDeadline(time.Now().Add(replyWait))
	var reply [1]byte
	if _, err := io.ReadFull(conn, reply[:]); err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return nil, 0, c.subFailed(i, conn, err)
		}
		// Through the lane, but the bond server closed without a word: the key
		// or the clock do not match.
		_ = conn.Close()
		return nil, 0, errors.Join(errNoBond, err)
	}
	_ = conn.SetDeadline(time.Time{})
	c.laneOK(i)
	return conn, reply[0], nil
}

func (c *Client) subFailed(i int, conn net.Conn, err error) error {
	_ = conn.Close()
	c.laneFailed(i)
	return err
}

// redial gives a stream a sub-connection on a lane it lost or never had, for
// as long as the stream lasts: a lane's runtime can be gone for minutes and
// come back on the same port. The wait doubles with every failed call up to
// redialMax redialBases, a lane that sits out is called again as soon as its
// bench is over, and the wait ends early when the lane carries again for
// anyone. The hello says it is a rejoin, so a bond server that does not know
// the stream (it was restarted) turns it away instead of opening it again,
// and the stream ends at once rather than hang.
func (c *Client) redial(st *stripe, i, total int, session [16]byte, target string) {
	delay := redialBase
	back := c.laneBack(i)
	for {
		wait := time.NewTimer(c.redialWait(i, delay))
		select {
		case <-st.done:
			wait.Stop()
			return
		case <-wait.C:
		case <-back:
			wait.Stop()
		}
		// Taken before claim, so a call that another stream makes meanwhile
		// and that brings the lane back still wakes this one.
		back = c.laneBack(i)
		ok, probe := c.claim(i)
		if !ok {
			continue
		}
		conn, reply, err := c.dialSub(i, total, session, target, true)
		if probe {
			c.unclaim(i)
		}
		if err != nil {
			delay = min(2*delay, redialMax*redialBase)
			continue
		}
		if reply != replyOK {
			_ = conn.Close()
			st.peerGone()
			return
		}
		st.add(i, conn, c.statsOf(i))
		return
	}
}

// plainRelay hands the request to one lane as it is and relays both ways;
// the lane's own reply goes back to the app.
func (c *Client) plainRelay(app net.Conn, req socksRequest) {
	if req.cmd != cmdConnect && req.cmd != 3 { // CONNECT, UDP ASSOCIATE
		_, _ = app.Write(socksReply(repCmdNotSupported))
		return
	}
	i := c.nextLane()
	if i < 0 {
		_, _ = app.Write(socksReply(repFailure))
		return
	}
	l, _ := c.laneAt(i)
	conn, err := net.DialTimeout("tcp", laneAddr(l.port), 5*time.Second)
	if err != nil {
		c.laneFailed(i)
		_, _ = app.Write(socksReply(repNetUnreachable))
		return
	}
	if !c.track(conn) {
		_ = conn.Close()
		return
	}
	defer c.untrack(conn)
	_ = conn.SetDeadline(time.Now().Add(handshakeMax))
	_, err = conn.Write(append(greeting(l.user, l.pass), req.raw...))
	if err == nil {
		err = readGreetingReply(conn, l.user)
	}
	if err != nil {
		_ = c.subFailed(i, conn, err)
		_, _ = app.Write(socksReply(repFailure))
		return
	}
	_ = conn.SetDeadline(time.Time{})
	c.plain.Add(1)
	relay(app, countedConn{Conn: conn, stats: c.statsOf(i)})
}

// countedConn counts what passes through a lane outside a stripe: reads are
// toward the app.
type countedConn struct {
	net.Conn
	stats *laneStats
}

func (c countedConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	if c.stats != nil {
		c.stats.rx.Add(int64(n))
	}
	return n, err
}

func (c countedConn) Write(p []byte) (int, error) {
	n, err := c.Conn.Write(p)
	if c.stats != nil {
		c.stats.tx.Add(int64(n))
	}
	return n, err
}

// CloseWrite keeps the half-close the relay passes on.
func (c countedConn) CloseWrite() error {
	if cw, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}
	return nil
}

// relay copies both ways until both are done; an error ends both at once.
func relay(a, b net.Conn) {
	var wg sync.WaitGroup
	pass := func(dst, src net.Conn) {
		defer wg.Done()
		if _, err := io.Copy(dst, src); err != nil {
			_ = a.Close()
			_ = b.Close()
			return
		}
		closeWrite(dst)
	}
	wg.Add(2)
	go pass(a, b)
	go pass(b, a)
	wg.Wait()
	_ = a.Close()
	_ = b.Close()
}

func closeLate(results <-chan subResult, left int) {
	for ; left > 0; left-- {
		if r := <-results; r.conn != nil {
			_ = r.conn.Close()
		}
	}
}

// resetAndClose tells the server the stream is over before closing a
// sub-connection, briefly.
func resetAndClose(c net.Conn) {
	_ = c.SetWriteDeadline(time.Now().Add(time.Second))
	_, _ = c.Write(appendReset(nil))
	_ = c.Close()
}

type stripeStop struct{ st *stripe }

// Close ends the stream and tells the server, which would otherwise hold the
// target until its lanes time out; off the caller's thread, as Stop closes
// every stream at once and the lanes may be on their way down already.
func (s *stripeStop) Close() error {
	go s.st.fail(errStopped)
	return nil
}

func laneAddr(port int) string { return net.JoinHostPort("127.0.0.1", strconv.Itoa(port)) }

func (c *Client) track(x io.Closer) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.stopped {
		return false
	}
	c.open[x] = struct{}{}
	return true
}

func (c *Client) untrack(x io.Closer) {
	c.mu.Lock()
	delete(c.open, x)
	c.mu.Unlock()
}

func (c *Client) bonding() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.lanes) >= 2 && !time.Now().Before(c.offUntil)
}

func (c *Client) isOff() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Now().Before(c.offUntil)
}

func (c *Client) bondOff() {
	c.mu.Lock()
	was := time.Now().Before(c.offUntil)
	c.offUntil = time.Now().Add(bondOffFor)
	c.mu.Unlock()
	if !was {
		log.Printf("bond: the bond server at %s does not answer through the lanes; one lane per connection for %s", c.bondAddr, bondOffFor)
	}
}

func (c *Client) statsOf(i int) *laneStats {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lanes[i].stats
}

func (c *Client) laneAt(i int) (lane, []byte) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return *c.lanes[i], c.key
}

// pickLanes: the lanes not sitting out, or all when every one is.
func (c *Client) pickLanes() ([]int, int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	now := time.Now()
	var up, all []int
	for i, l := range c.lanes {
		all = append(all, i)
		if !now.Before(l.benched) {
			up = append(up, i)
		}
	}
	if len(up) == 0 {
		return all, len(c.lanes)
	}
	return up, len(c.lanes)
}

// nextLane takes turns over the lanes not sitting out; -1 without lanes.
func (c *Client) nextLane() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	n := len(c.lanes)
	if n == 0 {
		return -1
	}
	now := time.Now()
	for k := 0; k < n; k++ {
		i := (c.rr + k) % n
		if !now.Before(c.lanes[i].benched) {
			c.rr = (i + 1) % n
			return i
		}
	}
	i := c.rr % n
	c.rr = (i + 1) % n
	return i
}

func (c *Client) isBenched(i int) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return time.Now().Before(c.lanes[i].benched)
}

// laneBack is closed once lane i carries again after trouble.
func (c *Client) laneBack(i int) <-chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.lanes[i].back
}

// redialWait is how long a stream waits before it calls lane i back: delay,
// or until the lane's bench is over while it sits out.
func (c *Client) redialWait(i int, delay time.Duration) time.Duration {
	c.mu.Lock()
	defer c.mu.Unlock()
	if until := time.Until(c.lanes[i].benched); until > 0 {
		return until
	}
	return delay
}

// claim says whether a stream may call lane i back now: not while it sits
// out, and while it is in trouble only one stream at a time (probe: the
// caller unclaims it after its call). A lane whose room is gone parks every
// CONNECT in its core for up to a minute and refuses all of them once 64
// wait, so every open stream calling it at once would block it for everyone;
// the others hear the outcome through laneBack.
func (c *Client) claim(i int) (ok, probe bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	l := c.lanes[i]
	switch {
	case time.Now().Before(l.benched), l.probing:
		return false, false
	case l.troubled():
		l.probing = true
		return true, true
	}
	return true, false
}

func (c *Client) unclaim(i int) {
	c.mu.Lock()
	c.lanes[i].probing = false
	c.mu.Unlock()
}

// laneDropped: a stream lost its sub-connection on lane i.
func (c *Client) laneDropped(i int) {
	c.mu.Lock()
	c.lanes[i].dropped = true
	c.mu.Unlock()
}

func (c *Client) laneFailed(i int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	l := c.lanes[i]
	l.failures++
	if l.failures >= 2 {
		l.benched = time.Now().Add(benchFor)
		l.failures = 0
	}
}

func (c *Client) laneOK(i int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	l := c.lanes[i]
	if l.troubled() {
		close(l.back)
		l.back = make(chan struct{})
	}
	l.failures, l.benched, l.dropped = 0, time.Time{}, false
}
