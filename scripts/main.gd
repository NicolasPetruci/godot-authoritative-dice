extends Control
## Rolagem de dados em rede, em dois modos:
##
## - VULNERAVEL: o cliente rola o dado e envia o RESULTADO. O servidor confia
##   e repassa. Quem controla o cliente controla o resultado.
## - AUTORITATIVO: o cliente envia a INTENÇÃO ("quero rolar 2d6"). O servidor
##   valida o pedido, rola com o próprio gerador e distribui o resultado.
##
## O modo é escolhido por quem hospeda e vale no servidor. O cliente nunca
## decide em que modo o servidor opera.
##
## Toda a interface é montada por código para a cena ficar mínima e o
## arquivo ser legível direto no GitHub.

const PORT := 7777
const MAX_CLIENTS := 8
const SERVER_ID := 1

const DICE_COUNT := 2
const DICE_SIDES := 6

# Regras que só o servidor aplica (modo autoritativo).
const ALLOWED_SIDES: Array[int] = [4, 6, 8, 10, 12, 20, 100]
const MAX_DICE := 10
const MIN_INTERVAL_MS := 300

enum Mode { VULNERAVEL, AUTORITATIVO }

var mode: Mode = Mode.VULNERAVEL

var _online := false
var _rng := RandomNumberGenerator.new()
var _last_request_ms: Dictionary = {}  # peer_id -> instante do último pedido aceito

var _status: Label
var _host_button: Button
var _join_button: Button
var _mode_select: OptionButton
var _cheat_check: CheckBox
var _roll_button: Button
var _log_box: RichTextLabel


func _ready() -> void:
	_rng.randomize()
	_build_ui()

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)

	_refresh_ui()
	_log("Abra duas instâncias: uma hospeda, a outra entra.")


# --- Conexão -----------------------------------------------------------------

func _on_host_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_server(PORT, MAX_CLIENTS)
	if error != OK:
		_log("Não foi possível abrir a porta %d (erro %d). Já existe um servidor rodando?" % [PORT, error])
		return
	multiplayer.multiplayer_peer = peer
	_online = true
	_log("Servidor aberto na porta %d. Você é o jogador %d." % [PORT, SERVER_ID])
	_refresh_ui()


func _on_join_pressed() -> void:
	var peer := ENetMultiplayerPeer.new()
	var error := peer.create_client("127.0.0.1", PORT)
	if error != OK:
		_log("Não foi possível iniciar a conexão (erro %d)." % error)
		return
	multiplayer.multiplayer_peer = peer
	_log("Conectando em 127.0.0.1:%d..." % PORT)
	_host_button.disabled = true
	_join_button.disabled = true


func _on_connected_to_server() -> void:
	_online = true
	_log("Conectado. Você é o jogador %d." % multiplayer.get_unique_id())
	_refresh_ui()


func _on_connection_failed() -> void:
	_log("A conexão falhou. O servidor está aberto?")
	_reset_connection()


func _on_server_disconnected() -> void:
	_log("O servidor encerrou a sessão.")
	_reset_connection()


func _on_peer_connected(peer_id: int) -> void:
	if not multiplayer.is_server():
		return
	_log("Jogador %d entrou." % peer_id)
	# Quem acabou de entrar precisa saber em que modo o servidor está.
	sync_mode.rpc_id(peer_id, mode)


func _on_peer_disconnected(peer_id: int) -> void:
	if multiplayer.is_server():
		_log("Jogador %d saiu." % peer_id)
		_last_request_ms.erase(peer_id)


func _reset_connection() -> void:
	multiplayer.multiplayer_peer = null
	_online = false
	_refresh_ui()


# --- Modo --------------------------------------------------------------------

func _on_mode_selected(index: int) -> void:
	if not (_online and multiplayer.is_server()):
		return
	mode = index as Mode
	_log("Modo alterado para: %s." % _mode_name())
	sync_mode.rpc(mode)
	_refresh_ui()


## Servidor -> clientes. Só a autoridade (o servidor) pode chamar.
@rpc("authority", "call_remote", "reliable")
func sync_mode(new_mode: int) -> void:
	mode = new_mode as Mode
	_log("O servidor está no modo: %s." % _mode_name())
	_refresh_ui()


# --- Rolagem: lado do cliente --------------------------------------------------

func _on_roll_pressed() -> void:
	var cheating := _cheat_check.button_pressed

	if mode == Mode.VULNERAVEL or cheating:
		# Caminho inseguro: o cliente monta o resultado e manda pronto.
		# No modo autoritativo isto é a tentativa de trapaça, e o servidor recusa.
		var rolls: Array = []
		for i in DICE_COUNT:
			rolls.append(DICE_SIDES if cheating else _rng.randi_range(1, DICE_SIDES))
		if multiplayer.is_server():
			submit_result(rolls)
		else:
			submit_result.rpc_id(SERVER_ID, rolls)
	else:
		# Caminho seguro: o cliente só diz o que quer fazer.
		if multiplayer.is_server():
			request_roll(DICE_COUNT, DICE_SIDES)
		else:
			request_roll.rpc_id(SERVER_ID, DICE_COUNT, DICE_SIDES)


# --- Rolagem: lado do servidor -------------------------------------------------

## VULNERÁVEL: recebe o resultado pronto do cliente.
@rpc("any_peer", "call_remote", "reliable")
func submit_result(rolls: Array) -> void:
	if not multiplayer.is_server():
		return
	var sender := _sender_id()

	if mode == Mode.AUTORITATIVO:
		# No modo autoritativo o servidor não aceita resultado de ninguém.
		announce_rejected.rpc(sender, "enviou um resultado pronto em vez de pedir a rolagem")
		return

	# Aqui está a falha: nenhuma validação. O servidor repassa o que vier.
	announce_roll.rpc(sender, rolls, false)


## AUTORITATIVO: recebe só a intenção. Nenhum número do resultado vem do cliente.
@rpc("any_peer", "call_remote", "reliable")
func request_roll(count: int, sides: int) -> void:
	if not multiplayer.is_server():
		return
	var sender := _sender_id()

	# 1. O pedido em si também é entrada não confiável: valida os parâmetros.
	if count < 1 or count > MAX_DICE or not ALLOWED_SIDES.has(sides):
		announce_rejected.rpc(sender, "pediu uma rolagem inválida (%dd%d)" % [count, sides])
		return

	# 2. Limite de frequência por jogador.
	var now := Time.get_ticks_msec()
	if now - int(_last_request_ms.get(sender, -MIN_INTERVAL_MS)) < MIN_INTERVAL_MS:
		return
	_last_request_ms[sender] = now

	# 3. O dado é rolado aqui, com o gerador do servidor.
	var rolls: Array = []
	for i in count:
		rolls.append(_rng.randi_range(1, sides))
	announce_roll.rpc(sender, rolls, true)


## Id de quem chamou o RPC. Vem do transporte, não de um parâmetro que o
## cliente preenche: o jogador não consegue rolar "em nome" de outro.
func _sender_id() -> int:
	var id := multiplayer.get_remote_sender_id()
	return id if id != 0 else multiplayer.get_unique_id()


# --- Resultado: servidor -> todos ----------------------------------------------

@rpc("authority", "call_local", "reliable")
func announce_roll(peer_id: int, rolls: Array, rolled_by_server: bool) -> void:
	var total := 0
	for value in rolls:
		total += int(value)
	var origin := "rolado pelo servidor" if rolled_by_server else "informado pelo cliente"
	_log("Jogador %d: %s = %d  (%s)" % [peer_id, str(rolls), total, origin])


@rpc("authority", "call_local", "reliable")
func announce_rejected(peer_id: int, reason: String) -> void:
	_log("RECUSADO. Jogador %d %s." % [peer_id, reason])


# --- Interface ---------------------------------------------------------------

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title := Label.new()
	title.text = "Dados em rede: quem decide o resultado?"
	title.add_theme_font_size_override("font_size", 22)
	column.add_child(title)

	_status = Label.new()
	column.add_child(_status)

	var connection_row := HBoxContainer.new()
	connection_row.add_theme_constant_override("separation", 8)
	column.add_child(connection_row)

	_host_button = Button.new()
	_host_button.text = "Hospedar"
	_host_button.pressed.connect(_on_host_pressed)
	connection_row.add_child(_host_button)

	_join_button = Button.new()
	_join_button.text = "Entrar (127.0.0.1)"
	_join_button.pressed.connect(_on_join_pressed)
	connection_row.add_child(_join_button)

	_mode_select = OptionButton.new()
	_mode_select.add_item("Vulnerável: o cliente envia o resultado", Mode.VULNERAVEL)
	_mode_select.add_item("Autoritativo: o servidor rola", Mode.AUTORITATIVO)
	_mode_select.item_selected.connect(_on_mode_selected)
	column.add_child(_mode_select)

	_cheat_check = CheckBox.new()
	_cheat_check.text = "Trapacear: enviar %d em todos os dados" % DICE_SIDES
	column.add_child(_cheat_check)

	_roll_button = Button.new()
	_roll_button.text = "Rolar %dd%d" % [DICE_COUNT, DICE_SIDES]
	_roll_button.pressed.connect(_on_roll_pressed)
	column.add_child(_roll_button)

	_log_box = RichTextLabel.new()
	_log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_box.scroll_following = true
	_log_box.selection_enabled = true
	column.add_child(_log_box)


func _refresh_ui() -> void:
	var is_host := _online and multiplayer.is_server()

	_host_button.disabled = _online
	_join_button.disabled = _online
	_roll_button.disabled = not _online
	_cheat_check.disabled = not _online
	# Só quem hospeda escolhe o modo.
	_mode_select.disabled = not is_host
	_mode_select.select(mode)

	if not _online:
		_status.text = "Desconectado."
	elif is_host:
		_status.text = "Hospedando. Modo: %s." % _mode_name()
	else:
		_status.text = "Conectado como jogador %d. Modo: %s." % [multiplayer.get_unique_id(), _mode_name()]


func _mode_name() -> String:
	return "AUTORITATIVO" if mode == Mode.AUTORITATIVO else "VULNERÁVEL"


func _log(line: String) -> void:
	_log_box.add_text(line + "\n")
