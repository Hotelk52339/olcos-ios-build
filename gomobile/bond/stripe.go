package bond

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"sync"
	"sync/atomic"
	"time"
)

const (
	// windowFrames bounds how far past the peer's delivery point a frame may
	// be sent, and so the peer's reorder buffer: 4 MiB at most (frames of
	// 16 KiB), which an app that stops reading leaves full for as long.
	windowFrames = 256
	// acceptFrames is how far past its own delivery point a receiver takes
	// frames: the window of every sender so far, the older ones included.
	acceptFrames = 512
	// readAhead is how much of the local side is read before a lane takes it.
	readAhead = 256 << 10
	// ackEvery: a receiver reports at least this often per sub-connection,
	// and at once whenever it has read everything that had arrived.
	ackEvery = 32 << 10
	// subBuffer is a sub-connection's read buffer: frame heads and small
	// frames come through it, a larger payload straight into its own slice.
	subBuffer = 16 << 10

	// A lane may hold about its rate times (its base round trip +
	// queueTarget, or two round trips when that is more) unconfirmed, so
	// every lane's queue drains in about the same time and frames arrive
	// close to their turn, while a lane that is not full yet can still
	// double what it carries every round trip. A lane not measured yet starts
	// at capProbe and grows by what it delivers (doubling every round trip)
	// until its round trip shows a queue.
	capProbe    = 64 << 10
	capMax      = 16 << 20
	queueTarget = 200 * time.Millisecond
	sampleMin   = 200 * time.Millisecond
	// A lane takes a frame only when it would deliver it no later than the
	// soonest other lane could, plus that lane's own time or etaSlack,
	// whichever is more (a lane behind with what it holds counts as that much
	// later): one far slower than the rest, such as a room holding its speed
	// down to a trickle, would make the frame late for its turn and the peer
	// wait for it with everything after it. Lanes that are merely farther
	// away keep their share.
	etaSlack = queueTarget
	// etaGuess is when a frame on a lane with no round trip measured yet is
	// expected to arrive, so it is rescued soon if that lane is slow; a lane
	// that proves its speed in time has what it holds re-timed (retime).
	etaGuess = 150 * time.Millisecond

	// A frame another lane is rescueLate overdue with is sent again by the
	// next lane with room, and a timer wakes the writers for it, as nothing
	// else may on a quiet stream. A lane with nothing else to send also sends
	// again what another lane would deliver rescueMargin later than it. Only
	// the rescueScan oldest frames in flight are looked at; a frame is
	// rescued once.
	rescueScan   = 64
	rescueMargin = 20 * time.Millisecond
	rescueLate   = 150 * time.Millisecond
	checkMin     = 50 * time.Millisecond

	// A lane kept off frames for being slow (timely) carries a copy of a
	// frame another lane holds every probeEvery while the stream sends: the
	// stream never waits for the copy, and its round trip shows how fast the
	// lane carries now (learn). A room out of a dark spell, or held down for a
	// while and let go, is used again within probeEvery; without the probe a
	// lane judged slow got no frame to prove otherwise for the stream's life,
	// and every new stream took its old reading from the lane's stats.
	probeEvery = 3 * time.Second

	// A sub-connection that confirms nothing for stallAfter (at least
	// stallMin) has its frames sent again over the others; one stalled for
	// stallDrop is closed and dialed again.
	stallMin  = 2 * time.Second
	stallDrop = 30 * time.Second
	// orphanWait is how long a stream with no sub-connection left waits for
	// a new one before it gives up.
	orphanWait = 30 * time.Second
	// lingerWait bounds the goodbye: the last acks out, then the peer's end.
	lingerWait = 2 * time.Second
)

var (
	errLanesLost = errors.New("bond: every lane is gone")
	errPeerGone  = errors.New("bond: the other side ended the stream")
	errPeerReset = errors.New("bond: the other side failed the stream")
)

// stripe carries one byte stream in each direction over a changing set of
// sub-connections.
//
// Out: the local side is cut into numbered frames; a sub-connection's writer
// takes the next frame while its lane has room (see sub.capacity) and keeps
// it on the lane's list until the peer confirms it. Frames of a lane that
// dies or stalls go to the front of the queue again, and a lane that would
// otherwise idle sends again what a slower lane still holds. In: every
// sub-connection's reader files frames by number, dropping copies; one
// writer passes them to the local side in order.
//
// The end of a direction is a numbered frame of its own, so it travels,
// waits and is resent like data. The stream is over when both ends are
// delivered and confirmed; it fails when no sub-connection is left for
// orphanWait, or on a local error.
type stripe struct {
	local io.ReadWriteCloser
	// onLoss hears that a sub-connection of a lane went away while the
	// stream still needs it. Set before the first add.
	onLoss func(lane int)

	// mu guards the stripe's state and every sub's but c, r, lane and stats,
	// which are fixed at add. A laneStats has its own mutex, taken under mu,
	// last; nothing else is locked while mu is held, and onLoss is called
	// after it is released.
	mu       sync.Mutex
	outCond  *sync.Cond // writers wait here
	inCond   *sync.Cond // the local writer waits here
	readCond *sync.Cond // the local reader waits here
	subs     []*sub     // the live ones
	readers  sync.WaitGroup
	writers  sync.WaitGroup
	// orphanSince: since when no sub-connection is live (zero while one is).
	orphanSince time.Time
	timer       *time.Timer
	timerAt     time.Time

	// Out.
	frames     map[uint32]*outFrame // cut, not yet confirmed
	fresh      []uint32             // never sent, in order
	freshBytes int
	resend     []uint32 // to send again, in order
	nextSeq    uint32
	ended      bool   // the local side's reading half is over, its end frame cut
	peerNext   uint32 // the peer delivered every frame below this

	// In.
	pending      map[uint32][]byte
	next         uint32
	finSeq       int64 // the peer's end frame, -1 until seen
	inDone       bool  // the peer's end is delivered
	ackNext      bool  // `next` moved far enough to be worth an ack of its own
	reportedNext uint32

	closing bool  // both directions are over: the goodbye is under way
	over    bool  // closed down
	failed  error // why, when it was not a clean end

	done     chan struct{}
	doneOnce sync.Once
}

type outFrame struct {
	payload []byte    // empty: the end frame
	holder  *sub      // the lane it was last sent on
	due     time.Time // when it should reach the peer that way
	rescued bool
}

type sub struct {
	lane  int
	c     net.Conn
	r     *bufio.Reader
	stats *laneStats
	dead  bool

	// Out, on this lane.
	sent      int64    // frame bytes written
	peerGot   int64    // frame bytes the peer reports as arrived
	flights   []flight // frames written here and not confirmed yet, in order
	progress  time.Time
	stalled   bool
	stalledAt time.Time
	rate      float64 // bytes per second the lane delivers
	minRTT    time.Duration
	sampleAt  time.Time
	sampleGot int64
	busy      bool // the lane, not the stream, held frames back this sample
	// proven: rate was read while the lane, not the stream, set the pace.
	// Until then it is only a floor (a lane that carried pings reads as a
	// few bytes a second) and the lane is treated as still probing.
	proven   bool
	startup  bool // still finding its speed: may carry startCap
	startCap int64
	// probedAt is when the lane last carried a probe copy (probeEvery);
	// probeNext marks the frame take just handed out as one.
	probedAt  time.Time
	probeNext bool

	// In, on this lane.
	got      int64
	reported int64
	ackDue   bool
}

type flight struct {
	seq  uint32
	end  int64 // sub.sent once this frame was written
	at   time.Time
	due  time.Time // when it should reach the peer this way
	size int       // payload bytes
	// probe: a copy sent to measure the lane, not to carry the stream.
	probe bool
}

func newStripe(local io.ReadWriteCloser) *stripe {
	s := &stripe{
		local:       local,
		frames:      make(map[uint32]*outFrame),
		pending:     make(map[uint32][]byte),
		finSeq:      -1,
		orphanSince: time.Now(),
		done:        make(chan struct{}),
	}
	s.outCond = sync.NewCond(&s.mu)
	s.inCond = sync.NewCond(&s.mu)
	s.readCond = sync.NewCond(&s.mu)
	s.timer = time.AfterFunc(orphanWait, s.check)
	s.timerAt = s.orphanSince.Add(orphanWait)
	return s
}

// run moves the stream until it is over; nil for a clean end.
func (s *stripe) run() error {
	go s.pumpOut()
	s.pumpIn()
	<-s.done
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.failed
}

// add puts one more sub-connection to work; false (and c closed) when the
// stream is already over. stats, when given, is what earlier streams learned
// about the lane, and what this one teaches the next.
func (s *stripe) add(lane int, c net.Conn, stats *laneStats) bool {
	s.mu.Lock()
	if s.closing || s.over {
		s.mu.Unlock()
		_ = c.Close()
		return false
	}
	sb := &sub{lane: lane, c: c, r: bufio.NewReaderSize(c, subBuffer), stats: stats, startCap: capProbe}
	if stats != nil {
		sb.rate, sb.minRTT = stats.load()
	}
	sb.proven = sb.rate > 0
	sb.startup = sb.rate <= 0
	s.subs = append(s.subs, sb)
	s.orphanSince = time.Time{}
	s.readers.Add(1)
	s.writers.Add(1)
	s.outCond.Broadcast()
	s.mu.Unlock()
	go s.write(sb)
	go s.read(sb)
	return true
}

// isOver: no sub-connection can join any more.
func (s *stripe) isOver() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.closing || s.over
}

// pumpOut cuts the local side into frames until it ends.
func (s *stripe) pumpOut() {
	buf := make([]byte, maxPayload)
	for {
		s.mu.Lock()
		for s.freshBytes >= readAhead && !s.over {
			s.readCond.Wait()
		}
		over := s.over
		s.mu.Unlock()
		if over {
			return
		}
		n, err := s.local.Read(buf)
		s.mu.Lock()
		if n > 0 && !s.over {
			s.cut(append([]byte(nil), buf[:n]...))
			s.freshBytes += n
		}
		if err != nil && isClosed(err) && !s.over {
			s.cut([]byte{})
			s.ended = true
		}
		s.outCond.Broadcast()
		s.mu.Unlock()
		if err != nil {
			if !isClosed(err) {
				s.fail(err)
			}
			return
		}
	}
}

func (s *stripe) cut(p []byte) {
	s.frames[s.nextSeq] = &outFrame{payload: p}
	s.fresh = append(s.fresh, s.nextSeq)
	s.nextSeq++
}

// write sends this lane's share: acks first, then frames while it has room.
func (s *stripe) write(sb *sub) {
	defer s.writers.Done()
	var buf []byte // grows on first use: an idle sub-connection stays small
	for {
		buf = buf[:0]
		s.mu.Lock()
		for {
			if sb.dead || s.over {
				s.mu.Unlock()
				return
			}
			if sb.ackDue || s.ackNext {
				buf = appendAck(buf, s.next, sb.got)
				sb.reported, sb.ackDue = sb.got, false
				s.reportedNext, s.ackNext = s.next, false
			}
			if !s.closing {
				now := time.Now()
				if seq, f, ok := s.take(sb, now); ok {
					due := now.Add(sb.eta(len(f.payload)))
					buf = appendFrame(buf, seq, f.payload)
					sb.sent += frameSize(f.payload)
					if sb.stats != nil {
						sb.stats.tx.Add(frameSize(f.payload))
					}
					if sb.sampleAt.IsZero() {
						// The first rate sample spans from here, so a lane
						// is measured on its first confirmation that comes
						// sampleMin later, however slow it is.
						sb.sampleAt, sb.sampleGot = now, sb.peerGot
					}
					probe := sb.probeNext
					sb.probeNext = false
					sb.flights = append(sb.flights, flight{seq: seq, end: sb.sent, at: now, due: due,
						size: len(f.payload), probe: probe})
					if len(sb.flights) == 1 {
						s.arm(now.Add(sb.stallAfter()))
					}
					s.arm(due.Add(rescueLate))
				}
			}
			if len(buf) > 0 {
				break
			}
			if s.closing {
				s.mu.Unlock()
				return
			}
			s.outCond.Wait()
		}
		s.mu.Unlock()
		if _, err := sb.c.Write(buf); err != nil {
			s.lose(sb)
			return
		}
	}
}

// take picks what sb sends next: a frame to send again, else the next new
// one inside the peer's window, else a frame a slower lane holds; each only
// when sb would deliver it in good time (timely). A lane refused a new frame
// for its speed gets a probe copy now and then instead (probeCopy).
func (s *stripe) take(sb *sub, now time.Time) (uint32, *outFrame, bool) {
	if sb.stalled {
		return 0, nil, false
	}
	if sb.refresh() {
		s.retime(sb, now)
	}
	work := len(s.resend) > 0 || (len(s.fresh) > 0 && s.fresh[0]-s.peerNext < windowFrames)
	if sb.sent-sb.peerGot >= sb.capacity() {
		sb.busy = sb.busy || work
		return 0, nil, false
	}
	for len(s.resend) > 0 {
		seq := s.resend[0]
		f, ok := s.frames[seq]
		if !ok {
			s.resend = s.resend[1:]
			continue
		}
		if !s.timely(sb, len(f.payload), now) {
			break
		}
		s.resend = s.resend[1:]
		f.holder, f.due = sb, now.Add(sb.eta(len(f.payload)))
		return seq, f, true
	}
	if seq, f, ok := s.rescue(sb, now, true); ok {
		return seq, f, true
	}
	refused := false
	if len(s.fresh) > 0 && s.fresh[0]-s.peerNext < windowFrames {
		seq := s.fresh[0]
		if f := s.frames[seq]; s.timely(sb, len(f.payload), now) {
			s.fresh = s.fresh[1:]
			s.freshBytes -= len(f.payload)
			s.readCond.Signal()
			f.holder, f.due = sb, now.Add(sb.eta(len(f.payload)))
			return seq, f, true
		}
		refused = true
	}
	if seq, f, ok := s.rescue(sb, now, false); ok {
		return seq, f, true
	}
	if refused && len(sb.flights) == 0 && now.Sub(sb.probedAt) >= probeEvery {
		if seq, f, ok := s.probeCopy(sb); ok {
			sb.probedAt, sb.probeNext = now, true
			return seq, f, true
		}
	}
	return 0, nil, false
}

// probeCopy is a copy of the oldest frame another lane holds, for a lane
// kept off frames for being slow: the frame stays that lane's to deliver,
// so the stream does not wait for the copy, and the copy's round trip shows
// what the lane carries now (learn). An end frame has no bytes to measure.
func (s *stripe) probeCopy(sb *sub) (uint32, *outFrame, bool) {
	limit := s.nextSeq
	if len(s.fresh) > 0 {
		limit = s.fresh[0]
	}
	for seq, n := s.peerNext, 0; seq < limit && n < rescueScan; seq++ {
		f, ok := s.frames[seq]
		if !ok {
			continue
		}
		n++
		if f.holder == nil || f.holder == sb || f.holder.dead || len(f.payload) == 0 {
			continue
		}
		return seq, f, true
	}
	return 0, nil, false
}

// rescue sends again the oldest frame in flight on another lane that is
// overdue there, or (unless onlyLate, and only a lane that knows its own
// speed) that this lane would deliver clearly sooner.
func (s *stripe) rescue(sb *sub, now time.Time, onlyLate bool) (uint32, *outFrame, bool) {
	limit := s.nextSeq
	if len(s.fresh) > 0 {
		limit = s.fresh[0]
	}
	for seq, n := s.peerNext, 0; seq < limit && n < rescueScan; seq++ {
		f, ok := s.frames[seq]
		if !ok {
			continue
		}
		n++
		if f.rescued || f.holder == nil || f.holder == sb || f.holder.dead || f.holder.stalled {
			continue
		}
		if !now.Before(f.due.Add(rescueLate)) {
			// Late: worth a copy from any lane that is not slow itself, as
			// the frame is rescued only once.
			if !s.timely(sb, len(f.payload), now) {
				continue
			}
		} else if onlyLate || !sb.proven || !now.Add(sb.eta(len(f.payload))+rescueMargin).Before(f.due) {
			continue
		}
		f.rescued = true
		return seq, f, true
	}
	return 0, nil, false
}

// timely: sb would deliver a frame of n bytes sent now in good time next to
// every other lane (see etaSlack), each counted as late as it is behind
// already, and as slow as it has surely been (its floor, until it proves its
// speed). A lane that has not proven its own speed is let through to learn
// it; what it holds is rescued if it turns out slow.
func (s *stripe) timely(sb *sub, n int, now time.Time) bool {
	if !sb.proven {
		return true
	}
	mine := sb.reach(n) + sb.lateness(now)
	for _, o := range s.subs {
		if o == sb || o.dead || o.stalled {
			continue
		}
		if o.refresh() {
			s.retime(o, now)
		}
		if o.rate <= 0 {
			continue
		}
		if theirs := o.floorEta(n) + o.lateness(now); mine > theirs+max(etaSlack, theirs) {
			return false
		}
	}
	return true
}

// read files the peer's frames and acks from one sub-connection.
func (s *stripe) read(sb *sub) {
	defer s.readers.Done()
	for {
		f, err := readFrame(sb.r)
		if err != nil {
			s.lose(sb)
			return
		}
		if f.kind == kindReset {
			s.drop(errPeerReset)
			return
		}
		s.mu.Lock()
		if f.kind == kindAck {
			s.onAck(sb, f.seq, f.got)
			s.mu.Unlock()
			continue
		}
		sb.got += frameSize(f.payload)
		if sb.stats != nil {
			sb.stats.rx.Add(frameSize(f.payload))
		}
		if err := s.file(sb.lane, f); err != nil {
			s.mu.Unlock()
			s.fail(err)
			return
		}
		if sb.got-sb.reported >= ackEvery || sb.r.Buffered() == 0 {
			sb.ackDue = true
			s.outCond.Broadcast()
		}
		s.mu.Unlock()
	}
}

// file takes one data or end frame that came on lane.
func (s *stripe) file(lane int, f inFrame) error {
	if f.seq < s.next || (s.finSeq >= 0 && int64(f.seq) > s.finSeq) {
		return nil // a copy, or nothing
	}
	if f.seq-s.next >= acceptFrames {
		return &badFrameError{lane: lane, seq: f.seq, next: s.next, finSeq: s.finSeq, size: len(f.payload)}
	}
	if f.kind == kindEnd {
		s.finSeq = int64(f.seq)
	} else if _, ok := s.pending[f.seq]; !ok {
		s.pending[f.seq] = f.payload
	}
	s.inCond.Signal()
	return nil
}

// badFrameError is a frame further past the receiver's delivery point than
// any sender keeping to its window goes: bytes on a lane that are not what
// its sender wrote, or a sender out of step. It is errBadFrame to errors.Is,
// and says which lane brought it and its numbers, never what it carries.
type badFrameError struct {
	lane   int    // as the client numbers its lanes, from 0
	seq    uint32 // the frame's number
	next   uint32 // the receiver's delivery point
	finSeq int64  // the peer's end frame, -1 until seen
	size   int    // payload bytes; 0 for an end frame
}

func (e *badFrameError) Error() string { return errBadFrame.Error() + " " + e.where() }

func (e *badFrameError) Unwrap() error { return errBadFrame }

// where is the lane, counted from 1 as the app counts its rooms, and the
// numbers: "on lane 2 (seq 70123, expected from 69500, 1380 bytes)".
func (e *badFrameError) where() string {
	end := ""
	if e.finSeq >= 0 {
		end = fmt.Sprintf(", end at %d", e.finSeq)
	}
	return fmt.Sprintf("on lane %d (seq %d, expected from %d%s, %d bytes)", e.lane+1, e.seq, e.next, end, e.size)
}

// onAck takes the peer's report for sb: frames it confirms are done with,
// and the lane's rate and round trip are measured from it.
func (s *stripe) onAck(sb *sub, next uint32, got int64) {
	now := time.Now()
	if next > s.peerNext && next <= s.nextSeq {
		for seq := s.peerNext; seq < next; seq++ {
			delete(s.frames, seq)
		}
		s.peerNext = next
		s.outCond.Broadcast()
	}
	if got > sb.peerGot && got <= sb.sent {
		i := 0
		var newest time.Time
		var probed *flight
		for i < len(sb.flights) && sb.flights[i].end <= got {
			delete(s.frames, sb.flights[i].seq)
			newest = sb.flights[i].at
			if sb.flights[i].probe {
				p := sb.flights[i]
				probed = &p
			}
			i++
		}
		sb.flights = sb.flights[i:]
		if !newest.IsZero() {
			rtt := now.Sub(newest)
			if sb.minRTT == 0 || rtt < sb.minRTT {
				sb.minRTT = rtt
			}
			if sb.startup {
				if rtt > sb.minRTT+queueTarget {
					sb.startup = false
				} else {
					sb.startCap += got - sb.peerGot
				}
			}
		}
		if probed != nil {
			s.learn(sb, probed, now, got)
		}
		proven := sb.proven
		sb.sample(now, got)
		sb.peerGot = got
		sb.progress = now
		sb.stalled = false
		if !proven && sb.proven {
			s.retime(sb, now)
		}
		s.outCond.Broadcast()
	}
	s.maybeClose()
}

// learn takes a probe copy's round trip for the lane's speed: what its bytes
// took beyond the lane's round trip is the lane's rate now. Only a higher
// reading counts (a copy alone cannot show a lane slower than it has read),
// and no higher than the fastest other lane, as one frame's timing is too
// coarse to put a lane ahead of them; the frames the lane then takes measure
// it properly (sample), from here.
func (s *stripe) learn(sb *sub, fl *flight, now time.Time, got int64) {
	transit := max(now.Sub(fl.at)-sb.minRTT, time.Millisecond)
	r := float64(fl.size) / transit.Seconds()
	var fastest float64
	for _, o := range s.subs {
		if o != sb && !o.dead {
			fastest = max(fastest, o.rate)
		}
	}
	if fastest > 0 {
		r = min(r, fastest)
	}
	if r > sb.rate {
		sb.rate = r
	}
	sb.sampleAt, sb.sampleGot, sb.busy = now, got, false
}

// retime gives the frames sb holds the arrival times its speed says, once it
// has proven it: they went out with a guess, which a lane that is merely
// busy misses, and a frame rescued for that goes out twice for nothing.
func (s *stripe) retime(sb *sub, now time.Time) {
	for i := range sb.flights {
		fl := &sb.flights[i]
		fl.due = now.Add(time.Duration(float64(fl.end-sb.peerGot)/sb.rate*float64(time.Second)) + sb.minRTT/2)
		if f, ok := s.frames[fl.seq]; ok && f.holder == sb {
			f.due = fl.due
		}
	}
	if len(sb.flights) > 0 {
		s.arm(sb.flights[0].due.Add(rescueLate))
	}
}

// sample measures the lane's delivery rate over at least sampleMin (and a
// round trip). A lower reading counts only when the lane itself held frames
// back; otherwise the stream simply had less to send. A reading proves the
// lane's speed when the lane set the pace: it held frames back, or carried
// capProbe or more per sampleMin; only a proven rate is passed on to other
// streams.
func (sb *sub) sample(now time.Time, got int64) {
	if sb.sampleAt.IsZero() {
		sb.sampleAt, sb.sampleGot, sb.busy = now, got, false
		return
	}
	elapsed := now.Sub(sb.sampleAt)
	if elapsed < max(sampleMin, sb.minRTT) {
		return
	}
	r := float64(got-sb.sampleGot) / elapsed.Seconds()
	switch {
	case r > sb.rate:
		sb.rate = r
	case sb.busy:
		sb.rate = 0.75*sb.rate + 0.25*r
	}
	sb.proven = sb.proven || sb.busy || r*sampleMin.Seconds() >= capProbe
	sb.sampleAt, sb.sampleGot, sb.busy = now, got, false
	if sb.stats != nil && sb.proven {
		sb.stats.store(sb.rate, sb.minRTT)
	}
}

func (sb *sub) capacity() int64 {
	c := int64(capProbe)
	if sb.rate > 0 && sb.minRTT > 0 {
		c = int64(sb.rate * max(sb.minRTT+queueTarget, 2*sb.minRTT).Seconds())
	}
	if sb.startup {
		c = max(c, sb.startCap)
	}
	return min(max(c, capProbe), capMax)
}

// eta is how long a frame of n bytes sent now would take to reach the peer.
// A lane that has not proven its speed is taken to carry what it may per
// round trip, once a round trip is known, so what it holds is due soon and
// rescued soon if it turns out slow; before that, etaGuess.
func (sb *sub) eta(n int) time.Duration {
	queued := float64(sb.sent - sb.peerGot + int64(frameHead+n))
	switch {
	case sb.proven:
		return sb.floorEta(n)
	case sb.minRTT > 0:
		rate := max(sb.rate, float64(sb.startCap)/sb.minRTT.Seconds())
		return time.Duration(queued/rate*float64(time.Second)) + sb.minRTT/2
	default:
		return etaGuess
	}
}

// floorEta is eta at the rate the lane has shown: its speed once proven,
// until then a floor, so no sooner than it surely delivers. Needs a rate.
func (sb *sub) floorEta(n int) time.Duration {
	queued := float64(sb.sent - sb.peerGot + int64(frameHead+n))
	return time.Duration(queued/sb.rate*float64(time.Second)) + sb.minRTT/2
}

// reach is eta as the lane may soon prove it: one still finding its speed
// is judged by what it may carry a round trip, at most twice its rate (it
// doubles a round trip at best), as its rate so far only shows what it was
// given.
func (sb *sub) reach(n int) time.Duration {
	if !sb.proven || !sb.startup || sb.minRTT <= 0 {
		return sb.eta(n)
	}
	rate := max(sb.rate, min(float64(sb.startCap)/sb.minRTT.Seconds(), 2*sb.rate))
	queued := float64(sb.sent - sb.peerGot + int64(frameHead+n))
	return time.Duration(queued/rate*float64(time.Second)) + sb.minRTT/2
}

// lateness is how far the lane is behind with what it holds: its oldest
// frame in flight should have been confirmed by its due time plus the way
// back.
func (sb *sub) lateness(now time.Time) time.Duration {
	if len(sb.flights) == 0 {
		return 0
	}
	return max(0, now.Sub(sb.flights[0].due.Add(sb.minRTT/2)))
}

// refresh gives a lane that has not proven its speed on this stream yet
// what another stream through it has proven since; true when it did.
// laneStats.mu is taken under stripe.mu, never the other way round.
func (sb *sub) refresh() bool {
	if sb.proven || sb.stats == nil {
		return false
	}
	rate, minRTT := sb.stats.load()
	if rate <= 0 {
		return false
	}
	sb.rate, sb.proven = rate, true
	if sb.minRTT == 0 || (minRTT > 0 && minRTT < sb.minRTT) {
		sb.minRTT = minRTT
	}
	return true
}

func (sb *sub) stallAfter() time.Duration {
	return max(stallMin, 4*sb.minRTT+2*queueTarget)
}

// pumpIn passes the peer's frames to the local side in order, then ends the
// local side's writing half.
func (s *stripe) pumpIn() {
	for {
		s.mu.Lock()
		var payload []byte
		for payload == nil {
			if s.over {
				s.mu.Unlock()
				return
			}
			if p, ok := s.pending[s.next]; ok {
				payload = p
				delete(s.pending, s.next)
				s.next++
				if s.next-s.reportedNext >= windowFrames/8 {
					s.ackNext = true
					s.outCond.Broadcast()
				}
				break
			}
			if s.finSeq >= 0 && int64(s.next) == s.finSeq {
				s.next++
				s.inDone = true
				s.ackNext = true
				s.outCond.Broadcast()
				s.mu.Unlock()
				closeWrite(s.local)
				s.mu.Lock()
				s.maybeClose()
				s.mu.Unlock()
				return
			}
			s.inCond.Wait()
		}
		s.mu.Unlock()
		if _, err := s.local.Write(payload); err != nil {
			s.fail(err)
			return
		}
	}
}

// maybeClose starts the goodbye once both directions are delivered and
// confirmed: every lane sends a last ack (the peer may still wait to hear
// that its end arrived), ends its writing half, and the stream closes when
// the peer has done the same or lingerWait is up.
func (s *stripe) maybeClose() {
	if s.closing || s.over || !s.inDone || !s.ended || len(s.frames) != 0 {
		return
	}
	s.closing = true
	for _, sb := range s.subs {
		sb.ackDue = true
	}
	s.ackNext = true
	s.outCond.Broadcast()
	go func() {
		waitFor(&s.writers, lingerWait)
		s.mu.Lock()
		subs := slices.Clone(s.subs)
		s.mu.Unlock()
		for _, sb := range subs {
			closeWrite(sb.c)
		}
		waitFor(&s.readers, lingerWait)
		s.finish()
	}()
}

// lose takes a sub-connection out: its unconfirmed frames go to the others,
// and the owner hears about it while the stream still needs the lane.
func (s *stripe) lose(sb *sub) {
	s.mu.Lock()
	if sb.dead {
		s.mu.Unlock()
		return
	}
	sb.dead = true
	s.requeue(sb)
	s.subs = slices.DeleteFunc(s.subs, func(x *sub) bool { return x == sb })
	needed := !s.closing && !s.over
	if needed && len(s.subs) == 0 {
		s.orphanSince = time.Now()
		s.arm(s.orphanSince.Add(orphanWait))
	}
	s.outCond.Broadcast()
	s.mu.Unlock()
	_ = sb.c.Close()
	if needed && s.onLoss != nil {
		s.onLoss(sb.lane)
	}
}

// requeue sends sb's unconfirmed frames again, over whichever lanes take them.
func (s *stripe) requeue(sb *sub) {
	for _, f := range sb.flights {
		if _, ok := s.frames[f.seq]; ok {
			s.resend = append(s.resend, f.seq)
		}
	}
	sb.flights = nil
	slices.Sort(s.resend)
	s.resend = slices.Compact(s.resend)
}

// peerGone: the other side no longer knows this stream. That is the end
// when everything of ours is out and everything of theirs is in.
func (s *stripe) peerGone() {
	s.mu.Lock()
	clean := s.inDone && s.ended
	s.mu.Unlock()
	if clean {
		s.finish()
	} else {
		s.drop(errPeerGone)
	}
}

// arm makes sure check runs by `at`. Holds mu.
func (s *stripe) arm(at time.Time) {
	if s.over || (!s.timerAt.IsZero() && !at.Before(s.timerAt)) {
		return
	}
	s.timerAt = at
	s.timer.Reset(time.Until(at))
}

// check runs on the timer: stalled lanes hand their frames to the others,
// lanes stalled for too long are closed (and dialed again by the owner),
// and a stream left without lanes gives up after orphanWait.
func (s *stripe) check() {
	s.mu.Lock()
	if s.over {
		s.mu.Unlock()
		return
	}
	now := time.Now()
	s.timerAt = time.Time{}
	var next time.Time
	soonest := func(t time.Time) {
		if next.IsZero() || t.Before(next) {
			next = t
		}
	}
	var drop []net.Conn
	moved := false
	for _, sb := range s.subs {
		switch {
		case sb.stalled:
			if at := sb.stalledAt.Add(stallDrop); now.Before(at) {
				soonest(at)
			} else {
				drop = append(drop, sb.c)
			}
		case len(sb.flights) > 0:
			since := sb.flights[0].at
			if sb.progress.After(since) {
				since = sb.progress
			}
			if at := since.Add(sb.stallAfter()); now.Before(at) {
				soonest(at)
			} else {
				sb.stalled, sb.stalledAt = true, now
				s.requeue(sb)
				moved = true
				soonest(now.Add(stallDrop))
			}
		}
	}
	orphaned := false
	if len(s.subs) == 0 && !s.orphanSince.IsZero() && !s.closing {
		if at := s.orphanSince.Add(orphanWait); now.Before(at) {
			soonest(at)
		} else {
			orphaned = true
		}
	}
	// A frame late on its lane is rescued by the next writer with room, and
	// on a quiet stream nothing else wakes one: wake them here, and look
	// again while such a frame waits (no sooner than checkMin, as on a busy
	// stream the oldest frames' deadlines pass every few milliseconds). With
	// one lane left there is no one to rescue it.
	limit := s.nextSeq
	if len(s.fresh) > 0 {
		limit = s.fresh[0]
	}
	if len(s.subs) < 2 {
		limit = s.peerNext
	}
	again := now.Add(checkMin)
	for seq, n := s.peerNext, 0; seq < limit && n < rescueScan; seq++ {
		f, ok := s.frames[seq]
		if !ok {
			continue
		}
		n++
		if f.rescued || f.holder == nil || f.holder.dead || f.holder.stalled {
			continue
		}
		at := f.due.Add(rescueLate)
		if !now.Before(at) {
			moved = true
		}
		if at.Before(again) {
			at = again
		}
		soonest(at)
	}
	if moved {
		s.outCond.Broadcast()
	}
	if !next.IsZero() {
		s.arm(next)
	}
	s.mu.Unlock()
	for _, c := range drop {
		_ = c.Close() // its reader fails, and lose() takes it from there
	}
	if orphaned {
		s.drop(errLanesLost)
	}
}

// fail ends the stream on a local error and tells the peer, which would
// otherwise keep its side open until its lanes time out.
func (s *stripe) fail(err error) {
	s.mu.Lock()
	if s.over {
		s.mu.Unlock()
		return
	}
	subs := slices.Clone(s.subs)
	s.mu.Unlock()
	var told sync.WaitGroup
	for _, sb := range subs {
		told.Add(1)
		go func() {
			defer told.Done()
			_ = sb.c.SetWriteDeadline(time.Now().Add(time.Second))
			_, _ = sb.c.Write(appendReset(nil))
		}()
	}
	told.Wait()
	s.drop(err)
}

// drop ends the stream without telling the peer.
func (s *stripe) drop(err error) {
	s.mu.Lock()
	if s.failed == nil && !s.over {
		s.failed = err
	}
	s.mu.Unlock()
	s.finish()
}

// finish closes everything once; the peer sees its sub-connections close.
func (s *stripe) finish() {
	s.doneOnce.Do(func() {
		s.mu.Lock()
		s.over = true
		s.timer.Stop()
		subs := slices.Clone(s.subs)
		s.outCond.Broadcast()
		s.inCond.Broadcast()
		s.readCond.Broadcast()
		s.mu.Unlock()
		for _, sb := range subs {
			_ = sb.c.Close()
		}
		_ = s.local.Close()
		close(s.done)
	})
}

// laneStats is what the streams on one lane learned about it: a new stream
// starts from it instead of probing. rx and tx count the bytes the lane
// carried for every stream, toward the app and from it. Its mutex is the
// last one taken (under a stripe's mu) and takes no other.
type laneStats struct {
	mu     sync.Mutex
	rate   float64
	minRTT time.Duration
	at     time.Time

	rx, tx atomic.Int64
}

// statsFor is how long a lane's measurement stays good without a new one.
const statsFor = 5 * time.Minute

func (l *laneStats) load() (float64, time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if time.Since(l.at) > statsFor {
		return 0, 0
	}
	return l.rate, l.minRTT
}

func (l *laneStats) store(rate float64, minRTT time.Duration) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if time.Since(l.at) > statsFor {
		l.minRTT = 0
	}
	l.rate = rate
	if minRTT > 0 && (l.minRTT == 0 || minRTT < l.minRTT) {
		l.minRTT = minRTT
	}
	l.at = time.Now()
}

func waitFor(wg *sync.WaitGroup, limit time.Duration) {
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(limit):
	}
}

func closeWrite(c io.ReadWriteCloser) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
	}
}

func isClosed(err error) bool {
	return errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF) || errors.Is(err, io.ErrClosedPipe)
}
