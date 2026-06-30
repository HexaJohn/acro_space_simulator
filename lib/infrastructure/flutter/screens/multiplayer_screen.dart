import 'package:flutter/material.dart';

import '../../../domain/multiplayer/command.dart';
import '../../../domain/multiplayer/player.dart';
import '../../../domain/multiplayer/session.dart';
import 'app_theme.dart';

/// Multiplayer authority demo. A [Session] of players, each owning assets;
/// compose commands and submit them — the session's [validate] guard accepts
/// only commands a player owns the target of, rejecting the rest. This is the
/// real core multiplayer rule (ownership-gated command stream), made visible.
class MultiplayerScreen extends StatefulWidget {
  const MultiplayerScreen({super.key});

  @override
  State<MultiplayerScreen> createState() => _MultiplayerScreenState();
}

class _MultiplayerScreenState extends State<MultiplayerScreen> {
  late Session _session;
  // The whole asset roster (some owned by each player, some neutral).
  final _assets = const ['vessel-alpha', 'vessel-bravo', 'colony-1', 'relay-7'];

  // Pending command batch the player is composing.
  final List<SimCommand> _pending = [];
  late PlayerId _asPlayer;
  String _asset = 'vessel-alpha';
  String _cmdType = 'throttle';
  // Validation result of the last submit.
  List<SimCommand>? _accepted;
  List<SimCommand> _rejected = const [];

  @override
  void initState() {
    super.initState();
    _session = Session(id: 'demo', players: [
      Player(
          id: const PlayerId('p1'),
          displayName: 'Commander Ada',
          ownedAssetIds: {'vessel-alpha', 'colony-1'}),
      Player(
          id: const PlayerId('p2'),
          displayName: 'Pilot Bo',
          ownedAssetIds: {'vessel-bravo'}),
      Player(
          id: const PlayerId('p3'),
          displayName: 'Observer Cy',
          ownedAssetIds: {}),
    ]);
    _asPlayer = _session.players.first.id;
  }

  Player get _currentPlayer => _session.player(_asPlayer)!;

  void _queue() {
    setState(() {
      _pending.add(switch (_cmdType) {
        'throttle' => SetThrottleCommand(_asPlayer, 0, _asset, 1.0),
        'stage' => SeparateStageCommand(_asPlayer, 0, _asset),
        'attitude' => SetAttitudeCommand(_asPlayer, 0, _asset, 0, 0, 1),
        _ => PlaceBuildingCommand(_asPlayer, 0, _asset, 'housing', 0, 0),
      });
    });
  }

  void _submit() {
    final batch = CommandBatch(_session.epoch, List.of(_pending));
    final accepted = _session.validate(batch);
    setState(() {
      _accepted = accepted;
      _rejected =
          _pending.where((c) => !accepted.contains(c)).toList();
      _pending.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppTheme.scaffold(
      context: context,
      title: 'MULTIPLAYER',
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _panel('SESSION — ${_session.players.length} players', [
            for (final p in _session.players) _playerRow(p),
            const SizedBox(height: 4),
            _kv('Authoritative tick', '${_session.authoritativeTick}'),
          ]),
          _panel('COMPOSE COMMAND', [
            _dropdownPlayer(),
            const SizedBox(height: 6),
            _dropdown('Target asset', _asset, _assets,
                (v) => setState(() => _asset = v)),
            const SizedBox(height: 6),
            _dropdown('Command', _cmdType,
                const ['throttle', 'stage', 'attitude', 'building'],
                (v) => setState(() => _cmdType = v)),
            const SizedBox(height: 6),
            Row(children: [
              Text(
                _currentPlayer.owns(_asset)
                    ? '${_currentPlayer.displayName} owns $_asset — will be accepted.'
                    : '${_currentPlayer.displayName} does NOT own $_asset — will be rejected.',
                style: AppTheme.dim.copyWith(
                    color: _currentPlayer.owns(_asset)
                        ? AppTheme.accent2
                        : AppTheme.warn),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.panelLight,
                    foregroundColor: AppTheme.accent),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('QUEUE'),
                onPressed: _queue,
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.accent,
                    foregroundColor: AppTheme.bg),
                icon: const Icon(Icons.send, size: 16),
                label: Text('SUBMIT (${_pending.length})'),
                onPressed: _pending.isEmpty ? null : _submit,
              ),
            ]),
          ]),
          if (_pending.isNotEmpty)
            _panel('PENDING BATCH', [
              for (final c in _pending) _cmdRow(c, null),
            ]),
          if (_accepted != null)
            _panel('VALIDATION RESULT', [
              Text('Accepted (${_accepted!.length})',
                  style: AppTheme.body.copyWith(color: AppTheme.accent2)),
              for (final c in _accepted!) _cmdRow(c, true),
              const SizedBox(height: 8),
              Text('Rejected (${_rejected.length}) — ownership guard',
                  style: AppTheme.body.copyWith(color: AppTheme.danger)),
              for (final c in _rejected) _cmdRow(c, false),
            ]),
        ],
      ),
    );
  }

  Widget _playerRow(Player p) {
    final me = p.id == _asPlayer;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: me ? AppTheme.accent.withValues(alpha: 0.1) : AppTheme.bg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
            color: me ? AppTheme.accent : const Color(0xFF223247)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: AppTheme.accent.withValues(alpha: 0.2),
            child: Text(p.displayName[0],
                style: const TextStyle(color: AppTheme.accent)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.displayName, style: AppTheme.body),
                Text(
                    p.ownedAssetIds.isEmpty
                        ? 'observer (no assets)'
                        : 'owns: ${p.ownedAssetIds.join(", ")}',
                    style: AppTheme.dim),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _cmdRow(SimCommand c, bool? accepted) {
    final issuer = _session.player(c.issuedBy)?.displayName ?? c.issuedBy.value;
    final color = accepted == null
        ? AppTheme.textDim
        : accepted
            ? AppTheme.accent2
            : AppTheme.danger;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(children: [
        Icon(
            accepted == null
                ? Icons.pending
                : accepted
                    ? Icons.check_circle
                    : Icons.cancel,
            size: 16,
            color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text('${_cmdName(c)} → ${c.targetAssetId}  ($issuer)',
              style: AppTheme.body),
        ),
      ]),
    );
  }

  String _cmdName(SimCommand c) => switch (c) {
        SetThrottleCommand() => 'Set throttle',
        SeparateStageCommand() => 'Separate stage',
        SetAttitudeCommand() => 'Set attitude',
        PlaceBuildingCommand() => 'Place building',
        ReportTerrainHeightCommand() => 'Report terrain',
      };

  Widget _dropdownPlayer() => Row(children: [
        const SizedBox(
            width: 110, child: Text('Acting as', style: AppTheme.body)),
        Expanded(
          child: DropdownButton<PlayerId>(
            value: _asPlayer,
            isExpanded: true,
            dropdownColor: AppTheme.panelLight,
            underline: Container(height: 1, color: AppTheme.accent),
            items: [
              for (final p in _session.players)
                DropdownMenuItem(
                    value: p.id,
                    child: Text(p.displayName, style: AppTheme.body)),
            ],
            onChanged: (v) => setState(() => _asPlayer = v!),
          ),
        ),
      ]);

  Widget _dropdown(String label, String value, List<String> options,
          ValueChanged<String> onChanged) =>
      Row(children: [
        SizedBox(width: 110, child: Text(label, style: AppTheme.body)),
        Expanded(
          child: DropdownButton<String>(
            value: value,
            isExpanded: true,
            dropdownColor: AppTheme.panelLight,
            underline: Container(height: 1, color: AppTheme.accent),
            items: [
              for (final o in options)
                DropdownMenuItem(value: o, child: Text(o, style: AppTheme.body)),
            ],
            onChanged: (v) => onChanged(v!),
          ),
        ),
      ]);

  Widget _panel(String title, List<Widget> children) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(14),
        decoration: AppTheme.panelBox(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTheme.heading),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(k, style: AppTheme.dim)),
          Text(v, style: AppTheme.mono),
        ]),
      );
}
