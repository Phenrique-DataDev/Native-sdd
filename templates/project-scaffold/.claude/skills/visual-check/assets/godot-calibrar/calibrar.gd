# Cena de controle da visual-check: escreve na tela o tamanho que o jogo montou.
# O PNG pode sair do tamanho pedido com a janela de outro (medido: 2560x1440 montou 2560x1421).
extends Control

func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color.WHITE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 40)
	l.add_theme_color_override("font_color", Color.BLACK)
	l.position = Vector2(16, 16)
	add_child(l)
	var s := get_viewport().get_visible_rect().size
	l.text = "W=%d H=%d" % [s.x, s.y]
	print("CALIBRAR W=%d H=%d" % [s.x, s.y])
