import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  String? _filePath;
  bool _repeatMode = false; // Flag to track repeat mode
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<Map<String, String>> _downloadedFiles = [];

  // Track current playing song
  Map<String, String>? _currentSong;
  // Track player state
  PlayerState _playerState = PlayerState.stopped;
  // Track current position and duration
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();

    // Set up listeners for audio player
    _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() {
        _playerState = state;
      });
    });

    _audioPlayer.onDurationChanged.listen((newDuration) {
      setState(() {
        _duration = newDuration;
      });
    });

    _audioPlayer.onPositionChanged.listen((newPosition) {
      setState(() {
        _position = newPosition;
      });
    });

    _audioPlayer.onPlayerComplete.listen((event) {
      if (_repeatMode) {
        _playMp3(_currentSong!['path']!); // Repeat the same song
      } else {
        // Play next song if available
        int currentIndex = _downloadedFiles.indexWhere((file) => file['path'] == _currentSong?['path']);
        int nextIndex = currentIndex + 1;
        if (nextIndex < _downloadedFiles.length) {
          _playMp3(_downloadedFiles[nextIndex]['path']!);
          setState(() {
            _currentSong = _downloadedFiles[nextIndex];
          });
        } else {
          setState(() {
            _playerState = PlayerState.stopped;
            _position = Duration.zero;
          });
        }
      }
    });
  }

  Future<void> _convertToMp3() async {
    String youtubeUrl = _urlController.text.trim();
    if (youtubeUrl.isEmpty) {
      _showMessage("Please enter a YouTube URL.");
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      var apiUrl = "http://192.168.0.42:8000/api/download-mp3";
      var response = await http.post(
        Uri.parse(apiUrl),
        body: {"url": youtubeUrl},
      );

      debugPrint("Response status: ${response.statusCode}");

      if (response.statusCode == 200) {
        String fileName = "downloaded_audio.mp3";
        String? contentDisposition = response.headers["content-disposition"];
        if (contentDisposition != null && contentDisposition.contains("filename=")) {
          fileName = contentDisposition.split("filename=")[1].replaceAll("\"", "");
        }

        Directory appDir = await getApplicationDocumentsDirectory();
        String filePath = "${appDir.path}/$fileName";
        File file = File(filePath);
        await file.writeAsBytes(response.bodyBytes);

        setState(() {
          // Do not override `_filePath` if a song is already playing
          if (_audioPlayer.state != PlayerState.playing) {
            _filePath = filePath;
          }
          _downloadedFiles.add({"name": fileName, "path": filePath});
          _isLoading = false;
        });

        _urlController.clear();

        Future.delayed(const Duration(milliseconds: 300), () {
          setState(() {});
        });

        _showMessage("Download complete! Tap to play.");
      } else {
        _showMessage("Failed to convert. Please try again.");
      }
    } catch (e) {
      debugPrint("Error: $e");
      _showMessage("Error: $e");
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _playMp3(String filePath) async {
    if (File(filePath).existsSync()) {
      await _audioPlayer.stop();
      await _audioPlayer.play(DeviceFileSource(filePath));
    } else {
      _showMessage("MP3 file not found.");
    }
  }

  void _pauseResume() async {
    if (_playerState == PlayerState.playing) {
      await _audioPlayer.pause();
    } else if (_playerState == PlayerState.paused) {
      await _audioPlayer.resume();
    } else if (_currentSong != null) {
      _playMp3(_currentSong!['path']!);
    }
  }

  void _stopPlaying() async {
    await _audioPlayer.stop();
    setState(() {
      _position = Duration.zero;
    });
  }

  void _seekTo(Duration position) async {
    await _audioPlayer.seek(position);
  }

  void _playNextSong() {
    if (_currentSong == null) return;

    int currentIndex = _downloadedFiles.indexWhere((file) => file['path'] == _currentSong?['path']);
    int nextIndex = currentIndex + 1;
    if (nextIndex < _downloadedFiles.length) {
      setState(() {
        _currentSong = _downloadedFiles[nextIndex];
      });
      _playMp3(_currentSong!['path']!);
    }
  }

  void _playPreviousSong() {
    if (_currentSong == null) return;

    int currentIndex = _downloadedFiles.indexWhere((file) => file['path'] == _currentSong?['path']);
    int prevIndex = currentIndex - 1;
    if (prevIndex >= 0) {
      setState(() {
        _currentSong = _downloadedFiles[prevIndex];
      });
      _playMp3(_currentSong!['path']!);
    }
  }

  void _toggleRepeatMode(StateSetter setModalState) {
    setState(() {
      _repeatMode = !_repeatMode;
    });

    setModalState(() {
      _repeatMode = _repeatMode;
    });

    _showMessage(_repeatMode ? "Repeat mode enabled" : "Repeat mode disabled");
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  void _showMusicPlayer(Map<String, String> song) {
    // Close any existing bottom sheet first
    Navigator.of(context).popUntil((route) => route.isFirst);

    setState(() {
      _currentSong = song;
    });

    _playMp3(song['path']!);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            // Function to update both parent and modal state
            void updateBothStates(Function() action) {
              setState(action);
              setModalState(action);
            }

            return Container(
              height: MediaQuery.of(context).size.height * 0.7,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.only(
                  topLeft: Radius.circular(20),
                  topRight: Radius.circular(20),
                ),
              ),
              child: Column(
                children: [
                  // Handle
                  Container(
                    margin: const EdgeInsets.only(top: 10),
                    width: 50,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.grey[300],
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),

                  // Album art placeholder
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 30),
                    width: 200,
                    height: 200,
                    decoration: BoxDecoration(
                      color: Colors.grey[200],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.music_note, size: 100, color: Colors.blue),
                  ),

                  // Song title
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _currentSong?['name'] ?? 'Unknown',
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Progress bar
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: StreamBuilder<Duration>(
                      stream: _audioPlayer.onPositionChanged,
                      builder: (context, snapshot) {
                        final position = snapshot.data ?? Duration.zero;

                        // Ensure position value doesn't exceed duration
                        final double positionInSeconds = position.inSeconds.toDouble();
                        final double maxDuration = _duration.inSeconds.toDouble() > 0 ?
                        _duration.inSeconds.toDouble() : 1.0;

                        // Constrain value to be within min and max
                        final double constrainedValue = positionInSeconds.clamp(0.0, maxDuration);

                        return Column(
                          children: [
                            Slider(
                              value: constrainedValue,
                              min: 0.0,
                              max: maxDuration,
                              onChanged: (value) {
                                _seekTo(Duration(seconds: value.toInt()));
                              },
                            ),

                            // Time indicators
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_formatDuration(position)),
                                  Text(_formatDuration(_duration)),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Control buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Previous button
                      IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_previous),
                        onPressed: () {
                          _playPreviousSong();
                          setModalState(() {}); // Update bottom sheet state
                        },
                      ),

                      const SizedBox(width: 16),

                      // Play/Pause button
                      StreamBuilder<PlayerState>(
                        stream: _audioPlayer.onPlayerStateChanged,
                        builder: (context, snapshot) {
                          final playerState = snapshot.data ?? PlayerState.stopped;
                          return Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: Colors.blue,
                              shape: BoxShape.circle,
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.blue.withOpacity(0.5),
                                  spreadRadius: 2,
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: IconButton(
                              iconSize: 40,
                              color: Colors.white,
                              icon: Icon(
                                playerState == PlayerState.playing ?
                                Icons.pause : Icons.play_arrow,
                              ),
                              onPressed: () {
                                _pauseResume();
                              },
                            ),
                          );
                        },
                      ),

                      const SizedBox(width: 16),

                      // Next button
                      IconButton(
                        iconSize: 40,
                        icon: const Icon(Icons.skip_next),
                        onPressed: () {
                          _playNextSong();
                          setModalState(() {}); // Update bottom sheet state
                        },
                      ),
                    ],
                  ),

                  const SizedBox(height: 10),
                  // Repeat and shuffle buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        iconSize: 30,
                        icon: Icon(
                          _repeatMode ? Icons.repeat_on : Icons.repeat,
                          color: _repeatMode ? Colors.blue : Colors.grey,
                        ),
                        onPressed: () {
                          _toggleRepeatMode(setModalState);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('YouTube to MP3'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: <Widget>[
            Expanded(
              child: _downloadedFiles.isEmpty
                  ? const Center(child: Text("No downloads yet"))
                  : ListView.builder(
                itemCount: _downloadedFiles.length,
                itemBuilder: (context, index) {
                  bool isPlaying = _currentSong != null &&
                      _currentSong!['path'] == _downloadedFiles[index]['path'] &&
                      _playerState == PlayerState.playing;

                  return ListTile(
                    leading: Icon(
                      isPlaying ? Icons.pause_circle_filled : Icons.music_note,
                      color: isPlaying ? Colors.blue : Colors.grey,
                      size: 40,
                    ),
                    title: Text(_downloadedFiles[index]['name'] ?? 'Unknown'),
                    subtitle: Text(isPlaying ? "Now playing" : "Tap to play"),
                    onTap: () {
                      _showMusicPlayer(_downloadedFiles[index]);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          showModalBottomSheet(
            context: context,
            isScrollControlled: true,
            builder: (context) {
              return Padding(
                padding: MediaQuery.of(context).viewInsets, // Avoid keyboard overlap
                child: SingleChildScrollView( // Allow scrolling if needed
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min, // Prevent unnecessary space usage
                      children: [
                        const Text(
                          "Enter YouTube URL",
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: _urlController,
                          decoration: const InputDecoration(
                            labelText: "YouTube URL",
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _convertToMp3();
                          },
                          child: const Text("Download MP3"),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
        child: const Icon(Icons.download),
      ),
    );
  }
}
