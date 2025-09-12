extends Node

func generate_chant_variant():
	var parts = [
		["Sili-sili","Tara, kain tayo","Sili-sili"],
		["maanghang","labis na anghang","singa"],
		["Tubig-tubig","malamig","sarap ng tubig"]
	]
	# simple shuffle & flatten: produce 10 beats
	var beats := []
	for i in range(10):
		var pick = parts[i % parts.size()].randi_range(0, parts[i % parts.size()].size()-1)
		beats.append(parts[i % parts.size()][pick])
	return beats
