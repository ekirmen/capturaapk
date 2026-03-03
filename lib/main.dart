import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';

// --- MODELOS ---
class ScaffoldCategory {
  String name;
  Color color;
  final String id;
  String? imagePath;

  ScaffoldCategory({required this.name, required this.color, required this.id, this.imagePath});

  Map<String, dynamic> toJson() => {
    'name': name,
    'color': color.value,
    'id': id,
    'imagePath': imagePath,
  };

  factory ScaffoldCategory.fromJson(Map<String, dynamic> json) => ScaffoldCategory(
    name: json['name'],
    color: Color(json['color']),
    id: json['id'],
    imagePath: json['imagePath'],
  );
}

class ScaffoldMarker {
  final Offset position;
  final ScaffoldCategory category;

  ScaffoldMarker({required this.position, required this.category});
}

// --- MAIN ---
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Solicitar permisos críticos antes de iniciar la app (principalmente para Android)
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    await [
      Permission.camera,
      Permission.storage,
      Permission.photos, // Para Android 13+ o iOS
    ].request();
  }

  List<CameraDescription> cameras = [];
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint("Error cámara o permisos no concedidos: $e");
  }

  runApp(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(
      primaryColor: Colors.amber,
      scaffoldBackgroundColor: const Color(0xFF121212),
      appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1E1E1E), centerTitle: true),
    ),
    home: MainNavigation(cameras: cameras),
  ));
}

class MainNavigation extends StatefulWidget {
  final List<CameraDescription> cameras;
  const MainNavigation({Key? key, required this.cameras}) : super(key: key);

  @override
  _MainNavigationState createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  List<ScaffoldCategory> categories = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('categories');
    
    if (data != null) {
      final List<dynamic> decoded = jsonDecode(data);
      setState(() {
        categories = decoded.map((e) => ScaffoldCategory.fromJson(e)).toList();
        isLoading = false;
      });
    } else {
      setState(() {
        categories = [
          ScaffoldCategory(name: 'Truss 2.5m', color: Colors.amber, id: '1'),
          ScaffoldCategory(name: 'Tarima 1.1', color: Colors.blueAccent, id: '2'),
        ];
        isLoading = false;
      });
    }
  }

  Future<void> _saveCategories(List<ScaffoldCategory> newList) async {
    final prefs = await SharedPreferences.getInstance();
    final String encoded = jsonEncode(newList.map((e) => e.toJson()).toList());
    await prefs.setString('categories', encoded);
    setState(() => categories = newList);
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    
    return widget.cameras.isEmpty 
      ? Scaffold(
          appBar: AppBar(title: const Text('Sin Cámara')),
          body: const Center(
            child: Text("Cámara no detectada o permisos denegados.\nVe a la configuración de tu teléfono y dale permiso a la cámara y al almacenamiento."),
          )
        )
      : TakePictureScreen(
          camera: widget.cameras.first, 
          categories: categories,
          onUpdateCategories: _saveCategories,
        );
  }
}

class TakePictureScreen extends StatefulWidget {
  final CameraDescription camera;
  final List<ScaffoldCategory> categories;
  final Function(List<ScaffoldCategory>) onUpdateCategories;

  const TakePictureScreen({
    Key? key, 
    required this.camera, 
    required this.categories,
    required this.onUpdateCategories,
  }) : super(key: key);

  @override
  TakePictureScreenState createState() => TakePictureScreenState();
}

class TakePictureScreenState extends State<TakePictureScreen> {
  late CameraController _controller;
  late Future<void> _initializeControllerFuture;
  final GlobalKey _repaintKey = GlobalKey();
  
  List<ScaffoldMarker> _markers = [];
  int _selectedIndex = 0;
  double _zoom = 1.0;
  double _maxZoom = 1.0;

  @override
  void initState() {
    super.initState();
    _controller = CameraController(
      widget.camera, 
      ResolutionPreset.high,
      enableAudio: false, // Previene ciertos crasheos al no pedir permiso de micro
    );
    _initializeControllerFuture = _controller.initialize().then((_) async {
      _maxZoom = await _controller.getMaxZoomLevel();
      setState(() {});
    }).catchError((e) {
      // Si el usuario deniega la cámara, aquí lo capturamos para evitar crash
      debugPrint("Error inicializando cámara: $e");
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _saveCapture() async {
    try {
      // 1. Solicitar permiso de galería al momento de guardar
      if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
        var status = await Permission.storage.request();
        var statusPhotos = await Permission.photos.request();
        if (!status.isGranted && !statusPhotos.isGranted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Error: Permiso de almacenamiento denegado.")));
           return;
        }
      }

      // 2. Tomar captura de la pantalla
      RenderRepaintBoundary boundary = _repaintKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      Uint8List pngBytes = byteData!.buffer.asUint8List();

      final String timestamp = DateTime.now().millisecondsSinceEpoch.toString();
      
      // 3. Guardar directamente en la Galería del teléfono
      final result = await ImageGallerySaver.saveImage(
        pngBytes,
        quality: 100,
        name: "captura_$timestamp"
      );
      
      if (result['isSuccess']) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("✅ Foto guardada exitosamente en la Galería", style: TextStyle(fontWeight: FontWeight.bold)), backgroundColor: Colors.green)
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("❌ Error al guardar en la galería"), backgroundColor: Colors.red)
        );
      }
    } catch (e) {
      debugPrint("Error guardando imagen: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CONTADOR PROFESIONAL'),
        actions: [
          IconButton(icon: const Icon(Icons.settings, color: Colors.amber), onPressed: () => _openSettings()),
          IconButton(icon: const Icon(Icons.save_alt, color: Colors.greenAccent), onPressed: _saveCapture),
          IconButton(
            icon: const Icon(Icons.undo),
            onPressed: () => setState(() { if(_markers.isNotEmpty) _markers.removeLast(); }),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            height: 60,
            color: Colors.black,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: widget.categories.map((cat) {
                int count = _markers.where((m) => m.category.id == cat.id).length;
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 15),
                  child: Center(
                    child: Text("${cat.name}: $count", 
                      style: TextStyle(color: cat.color, fontWeight: FontWeight.bold)),
                  ),
                );
              }).toList(),
            ),
          ),
          
          Expanded(
            child: RepaintBoundary(
              key: _repaintKey,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  FutureBuilder<void>(
                    future: _initializeControllerFuture,
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.done) {
                        return GestureDetector(
                          onTapDown: (details) {
                            setState(() {
                              _markers.add(ScaffoldMarker(
                                position: details.localPosition,
                                category: widget.categories[_selectedIndex],
                              ));
                            });
                          },
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              CameraPreview(_controller),
                              ..._markers.asMap().entries.map((entry) {
                                int idx = entry.key;
                                ScaffoldMarker m = entry.value;
                                return Positioned(
                                  left: m.position.dx - 15,
                                  top: m.position.dy - 15,
                                  child: GestureDetector(
                                    onTap: () => setState(() => _markers.removeAt(idx)),
                                    child: Column(
                                      children: [
                                        Icon(Icons.add_circle, color: m.category.color, size: 24),
                                        Text(m.category.name.substring(0, 1), 
                                          style: const TextStyle(fontSize: 8, color: Colors.white, backgroundColor: Colors.black45)),
                                      ],
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                        );
                      }
                      if (snapshot.hasError) {
                         return Center(
                           child: Padding(
                             padding: const EdgeInsets.all(20.0),
                             child: Text("Error de cámara.\nAsegúrate de haber otorgado los permisos: ${snapshot.error}", textAlign: TextAlign.center),
                           ),
                         );
                      }
                      return const Center(child: CircularProgressIndicator());
                    },
                  ),
                  
                  // FOTO DE REFERENCIA FLOTANTE
                  if (widget.categories.isNotEmpty && widget.categories[_selectedIndex].imagePath != null)
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white, width: 2),
                          borderRadius: BorderRadius.circular(10),
                          image: DecorationImage(
                            image: FileImage(File(widget.categories[_selectedIndex].imagePath!)),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),

                  Positioned(
                    top: 10,
                    left: 10,
                    child: Container(
                      padding: const EdgeInsets.all(5),
                      color: Colors.black54,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: widget.categories.map((cat) {
                          int count = _markers.where((m) => m.category.id == cat.id).length;
                          return Text("${cat.name}: $count", style: TextStyle(color: cat.color, fontSize: 10, fontWeight: FontWeight.bold));
                        }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
            color: Colors.black,
            child: Row(
              children: [
                const Icon(Icons.zoom_in, size: 20),
                Expanded(
                  child: Slider(
                      value: _zoom, min: 1.0, max: _maxZoom,
                      onChanged: (v) { setState(()=>_zoom=v); _controller.setZoomLevel(v); },
                  ),
                ),
              ],
            ),
          ),

          Container(
            height: 110,
            color: const Color(0xFF1E1E1E),
            child: widget.categories.isEmpty 
            ? const Center(child: Text("Ve a engranaje para crear un objeto"))
            : ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: widget.categories.length,
              itemBuilder: (context, index) {
                bool isSel = _selectedIndex == index;
                var cat = widget.categories[index];
                return GestureDetector(
                  onTap: () => setState(() => _selectedIndex = index),
                  child: Container(
                    width: 100,
                    margin: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: isSel ? cat.color.withAlpha(50) : Colors.transparent,
                      border: Border.all(color: isSel ? cat.color : Colors.white12, width: 2),
                      borderRadius: BorderRadius.circular(15),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (cat.imagePath != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Image.file(File(cat.imagePath!), width: 30, height: 30, fit: BoxFit.cover),
                          )
                        else
                          Icon(Icons.layers, color: cat.color, size: 20),
                        const SizedBox(height: 5),
                        Text(cat.name, textAlign: TextAlign.center, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openSettings() async {
    await Navigator.push(context, MaterialPageRoute(builder: (context) => 
      SettingsScreen(
        categories: widget.categories, 
        onSave: widget.onUpdateCategories,
      )));
    setState(() {});
  }
}

// --- PANTALLA DE CONFIGURACIÓN ---
class SettingsScreen extends StatefulWidget {
  final List<ScaffoldCategory> categories;
  final Function(List<ScaffoldCategory>) onSave;

  const SettingsScreen({Key? key, required this.categories, required this.onSave}) : super(key: key);

  @override
  _SettingsScreenState createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late List<ScaffoldCategory> tempCategories;
  final ImagePicker _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    tempCategories = List.from(widget.categories);
  }

  Future<void> _pickImage(int index) async {
    final XFile? image = await _picker.pickImage(source: ImageSource.gallery);
    if (image != null) {
      setState(() {
        tempCategories[index].imagePath = image.path;
      });
    }
  }

  void _addCategory() {
    setState(() {
      tempCategories.add(ScaffoldCategory(
        name: 'Nuevo Objeto', 
        color: Colors.primaries[tempCategories.length % Colors.primaries.length],
        id: DateTime.now().toString(),
      ));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configurar Inventario')),
      body: ListView.builder(
        itemCount: tempCategories.length,
        itemBuilder: (context, index) {
          return Card(
            margin: const EdgeInsets.all(8),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => _pickImage(index),
                        child: Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            color: Colors.black26,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(color: tempCategories[index].color),
                          ),
                          child: tempCategories[index].imagePath != null 
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.file(File(tempCategories[index].imagePath!), fit: BoxFit.cover),
                              )
                            : const Icon(Icons.add_a_photo, size: 20),
                        ),
                      ),
                      const SizedBox(width: 15),
                      Expanded(
                        child: TextFormField(
                          initialValue: tempCategories[index].name,
                          onChanged: (v) => tempCategories[index].name = v,
                          decoration: const InputDecoration(labelText: 'Nombre del objeto'),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => setState(() => tempCategories.removeAt(index)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addCategory,
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: ElevatedButton(
        style: ElevatedButton.styleFrom(padding: const EdgeInsets.all(20), backgroundColor: Colors.amber),
        onPressed: () { widget.onSave(tempCategories); Navigator.pop(context); },
        child: const Text('GUARDAR Y VOLVER', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
