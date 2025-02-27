package gossip

import (
	"context"
	"fmt"
	"net"

	"github.com/cockroachdb/errors"
	"github.com/iotaledger/hive.go/autopeering/peer"
	"github.com/iotaledger/hive.go/autopeering/peer/service"
	"github.com/iotaledger/hive.go/crypto"
	"github.com/libp2p/go-libp2p"

	"github.com/iotaledger/goshimmer/packages/gossip"
	"github.com/iotaledger/goshimmer/packages/libp2putil"
	"github.com/iotaledger/goshimmer/packages/tangle"
)

// ErrMessageNotFound is returned when a message could not be found in the Tangle.
var ErrMessageNotFound = errors.New("message not found")

var localAddr *net.TCPAddr

func createManager(lPeer *peer.Local, t *tangle.Tangle) *gossip.Manager {
	var err error

	// resolve the bind address
	localAddr, err = net.ResolveTCPAddr("tcp", Parameters.BindAddress)
	if err != nil {
		Plugin.LogFatalf("bind address '%s' is invalid: %s", Parameters.BindAddress, err)
	}

	// announce the gossip service
	if err := lPeer.UpdateService(service.GossipKey, localAddr.Network(), localAddr.Port); err != nil {
		Plugin.LogFatalf("could not update services: %s", err)
	}

	// loads the given message from the message layer and returns it or an error if not found.
	loadMessage := func(msgID tangle.MessageID) ([]byte, error) {
		cachedMessage := t.Storage.Message(msgID)
		defer cachedMessage.Release()
		if !cachedMessage.Exists() {
			if crypto.Randomness.Float64() < Parameters.MissingMessageRequestRelayProbability {
				t.Solidifier.RetrieveMissingMessage(msgID)
			}

			return nil, ErrMessageNotFound
		}
		msg := cachedMessage.Unwrap()
		return msg.Bytes(), nil
	}
	libp2pIdentity, err := libp2putil.GetLibp2pIdentity(lPeer)
	if err != nil {
		Plugin.LogFatalf("Could not build libp2p identity from local peer: %s", err)
	}
	libp2pHost, err := libp2p.New(
		context.Background(),
		libp2p.ListenAddrStrings(fmt.Sprintf("/ip4/%s/tcp/%d", localAddr.IP, localAddr.Port)),
		libp2pIdentity,
		libp2p.NATPortMap(),
	)
	if err != nil {
		Plugin.LogFatalf("Could create libp2p host: %s", err)
	}

	return gossip.NewManager(libp2pHost, lPeer, loadMessage, Plugin.Logger())
}

func start(ctx context.Context) {
	defer Plugin.LogInfo("Stopping " + PluginName + " ... done")

	defer deps.GossipMgr.Stop()
	defer func() {
		if err := deps.GossipMgr.Libp2pHost.Close(); err != nil {
			Plugin.LogWarn("Failed to close libp2p host: %+v", err)
		}
	}()

	Plugin.LogInfof("%s started: bind-address=%s", PluginName, localAddr.String())

	<-ctx.Done()
	Plugin.LogInfo("Stopping " + PluginName + " ...")
}
