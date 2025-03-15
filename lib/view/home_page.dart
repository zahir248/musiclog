import 'package:flutter/material.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:dio/dio.dart';

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
  bool _repeatAllMode = false; // Flag to track repeat all mode
  final AudioPlayer _audioPlayer = AudioPlayer();
  List<Map<String, String>> _downloadedFiles = [];

  double _downloadProgress = 0.0;

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

    // Scan the directory for MP3 files when app starts
    _scanMp3Directory();

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
        } else if (_repeatAllMode && _downloadedFiles.isNotEmpty) {
          // If repeat all is enabled and we're at the end of the list, go back to first song
          _playMp3(_downloadedFiles[0]['path']!);
          setState(() {
            _currentSong = _downloadedFiles[0];
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

  void _toggleRepeatAllMode(StateSetter setModalState) {
    setState(() {
      _repeatAllMode = !_repeatAllMode;
      // If enabling repeat all, disable single song repeat
      if (_repeatAllMode && _repeatMode) {
        _repeatMode = false;
      }
    });

    setModalState(() {
      _repeatAllMode = _repeatAllMode;
      _repeatMode = _repeatMode;
    });

    _showMessage(_repeatAllMode ? "Repeat all mode enabled" : "Repeat all mode disabled");
  }

  Future<void> _scanMp3Directory() async {
    try {
      Directory directory = Directory('/storage/emulated/0/Download/YTtoMP3');

      if (await directory.exists()) {
        List<FileSystemEntity> files = directory.listSync();
        List<Map<String, String>> mp3Files = [];

        for (var file in files) {
          if (file is File && file.path.toLowerCase().endsWith('.mp3')) {
            String fileName = file.path.split('/').last;
            mp3Files.add({"name": fileName, "path": file.path});
          }
        }

        setState(() {
          _downloadedFiles = mp3Files;
        });
      } else {
        // Create directory if it doesn't exist
        await directory.create(recursive: true);
      }
    } catch (e) {
      debugPrint("Error scanning MP3 directory: $e");
      _showMessage("Error scanning MP3 directory: $e");
    }
  }

  Future<void> _deleteFile(Map<String, String> file) async {
    try {
      File fileToDelete = File(file['path']!);

      // Check if file exists
      if (await fileToDelete.exists()) {
        // Check if this is the currently playing file
        bool isCurrentlyPlaying = _currentSong != null &&
            _currentSong!['path'] == file['path'] &&
            _playerState == PlayerState.playing;

        // If it's playing, stop it first
        if (isCurrentlyPlaying) {
          await _audioPlayer.stop();
          setState(() {
            _currentSong = null;
            _playerState = PlayerState.stopped;
          });
        }

        // Delete the file
        await fileToDelete.delete();

        // Remove from list
        setState(() {
          _downloadedFiles.removeWhere((item) => item['path'] == file['path']);
        });

        _showMessage("File deleted successfully");
      } else {
        _showMessage("File not found");
      }
    } catch (e) {
      debugPrint("Error deleting file: $e");
      _showMessage("Error deleting file: $e");
    }
  }

  Future<void> _convertToMp3() async {
    String youtubeUrl = _urlController.text.trim();
    if (youtubeUrl.isEmpty) {
      _showMessage("Please enter a YouTube URL.");
      return;
    }

    // Request storage permissions for Android
    if (Platform.isAndroid) {
      var status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
        if (!status.isGranted) {
          _showMessage("Storage permission is required");
          return;
        }
      }
    }

    setState(() {
      _isLoading = true;
      _downloadProgress = 0.0; // Reset progress
    });

    try {
      var apiUrl = "http://192.168.0.4:8000/api/download-mp3";

      Dio dio = Dio();

      // Make request to get the file
      var response = await dio.post(
        apiUrl,
        data: {"url": youtubeUrl},
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/x-www-form-urlencoded',
          },
        ),
        onReceiveProgress: (received, total) {
          if (total != -1) {
            setState(() {
              _downloadProgress = received / total;
            });
          }
        },
      );

      // Get and sanitize filename
      String fileName = _extractFileName(response);
      fileName = _sanitizeFileName(fileName); // Ensure valid filename

      // Create app folder in device storage
      Directory? directory;

      if (Platform.isAndroid) {
        directory = Directory('/storage/emulated/0/Download/YTtoMP3');
      } else if (Platform.isIOS) {
        directory = await getApplicationDocumentsDirectory();
        directory = Directory('${directory.path}/YTtoMP3');
      }

      // Create directory if it doesn't exist
      if (!(await directory!.exists())) {
        await directory.create(recursive: true);
      }

      String filePath = "${directory.path}/$fileName";
      File file = File(filePath);

      // Write the file with progress tracking
      List<int> bytes = [];
      await for (var chunk in response.data.stream) {
        bytes.addAll(chunk);
      }

      await file.writeAsBytes(bytes);

      setState(() {
        if (_audioPlayer.state != PlayerState.playing) {
          _filePath = filePath;
        }
        _downloadedFiles.add({"name": fileName, "path": filePath});
        _isLoading = false;
        _downloadProgress = 1.0; // Complete
      });

      // Save the updated list to preferences
      _saveDownloadedFiles();

      _urlController.clear();

      _showMessage("Download complete! File saved to ${directory.path}");
    } catch (e) {
      debugPrint("Error: $e");
      _showMessage("Error: $e");
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  String _extractFileName(Response response) {
    String defaultFileName = "downloaded_audio.mp3";
    String? contentDisposition = response.headers.value("content-disposition");

    if (contentDisposition != null && contentDisposition.contains("filename=")) {
      // Correct regex: Handles both UTF-8 and standard filenames
      RegExp regExp = RegExp(r'filename\*?=(?:utf-8\\|")?([^";]+)');
      Match? match = regExp.firstMatch(contentDisposition);

      if (match != null && match.group(1) != null) {
        return Uri.decodeFull(match.group(1)!.replaceAll('"', '').replaceAll("'", ""));
      }
    }
    return defaultFileName;
  }

  String _sanitizeFileName(String fileName) {
    return fileName
        .replaceAll(RegExp(r'[<>:"/\\|?*;]'), '') // Remove invalid characters
        .replaceAll(RegExp(r'\s+'), ' ') // Replace multiple spaces with a single space
        .trim();
  }

  Future<void> _renameFile(Map<String, String> file, String newTitle) async {
    try {
      // Get the current file path and create a File object
      File currentFile = File(file['path']!);

      // Check if file exists
      if (await currentFile.exists()) {
        // Get directory and file extension
        String directory = currentFile.parent.path;
        String extension = '.mp3';

        // Create new file path with new title
        String newPath = '$directory/$newTitle$extension';

        // Rename the file
        await currentFile.rename(newPath);

        // Update the file information in the list
        setState(() {
          int index = _downloadedFiles.indexWhere((item) => item['path'] == file['path']);
          if (index != -1) {
            _downloadedFiles[index] = {
              'name': '$newTitle$extension',
              'path': newPath
            };

            // If this is the currently playing song, update that reference too
            if (_currentSong != null && _currentSong!['path'] == file['path']) {
              _currentSong = _downloadedFiles[index];
            }
          }
        });

        _showMessage("File renamed successfully");
      } else {
        _showMessage("File not found");
      }
    } catch (e) {
      debugPrint("Error renaming file: $e");
      _showMessage("Error renaming file: $e");
    }
  }

  void _showEditDialog(Map<String, String> file) {
    String fileName = file['name'] ?? '';
    // Remove the extension for editing
    String fileNameWithoutExtension = fileName.endsWith('.mp3')
        ? fileName.substring(0, fileName.length - 4)
        : fileName;

    final TextEditingController _titleController = TextEditingController(text: fileNameWithoutExtension);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text("Edit Title"),
          content: TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: "Title",
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text("CANCEL"),
            ),
            TextButton(
              onPressed: () {
                String newTitle = _titleController.text.trim();
                if (newTitle.isNotEmpty) {
                  Navigator.of(context).pop();
                  _renameFile(file, newTitle);
                } else {
                  _showMessage("Title cannot be empty");
                }
              },
              child: const Text("SAVE"),
            ),
          ],
        );
      },
    );
  }

  // Save downloaded files list to SharedPreferences
  Future<void> _saveDownloadedFiles() async {
    final prefs = await SharedPreferences.getInstance();

    // Convert the list of maps to a list of strings that can be stored in SharedPreferences
    List<String> serializedFiles = _downloadedFiles.map((file) {
      return "${file['name']}|${file['path']}";  // Using | as a separator
    }).toList();

    await prefs.setStringList('downloadedFiles', serializedFiles);
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

    // Only set current song and start playing if it's a different song or not playing
    bool shouldStartPlaying = _currentSong == null ||
        _currentSong!['path'] != song['path'] ||
        _playerState == PlayerState.stopped;

    if (shouldStartPlaying) {
      setState(() {
        _currentSong = song;
      });
      _playMp3(song['path']!);
    }

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
                  // Repeat and shuffle buttons
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Repeat one button
                      IconButton(
                        iconSize: 30,
                        icon: Icon(
                          _repeatMode ? Icons.repeat_one : Icons.repeat,
                          color: _repeatMode ? Colors.blue : Colors.grey,
                        ),
                        onPressed: () {
                          _toggleRepeatMode(setModalState);
                        },
                      ),

                      // Repeat all button (new)
                      IconButton(
                        iconSize: 30,
                        icon: Icon(
                          Icons.repeat_on,
                          color: _repeatAllMode ? Colors.green : Colors.grey,
                        ),
                        onPressed: () {
                          _toggleRepeatAllMode(setModalState);
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
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            backgroundColor: Theme.of(context).colorScheme.inversePrimary,
            title: const Text('YouTube to MP3'),
            actions: [
              IconButton(
                icon: const Icon(Icons.download),
                onPressed: () {
                  showDialog(
                    context: context,
                    builder: (context) {
                      return Dialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12.0)), // Optional: Rounded corners
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
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
                      );
                    },
                  );
                },
              ),
            ],
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
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Edit button
                            IconButton(
                              icon: const Icon(Icons.edit, color: Colors.blue),
                              onPressed: () {
                                _showEditDialog(_downloadedFiles[index]);
                              },
                            ),
                            // Delete button
                            IconButton(
                              icon: const Icon(Icons.delete, color: Colors.red),
                              onPressed: () async {
                                bool confirm = await showDialog(
                                  context: context,
                                  barrierDismissible: false,
                                  builder: (BuildContext context) {
                                    return AlertDialog(
                                      title: const Text("Confirm Delete"),
                                      content: Text(
                                          "Are you sure you want to delete ${_downloadedFiles[index]['name']}?"),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.of(context).pop(false),
                                          child: const Text("CANCEL"),
                                        ),
                                        TextButton(
                                          onPressed: () => Navigator.of(context).pop(true),
                                          child: const Text("DELETE"),
                                        ),
                                      ],
                                    );
                                  },
                                );

                                if (confirm) {
                                  _deleteFile(_downloadedFiles[index]);
                                }
                              },
                            ),
                          ],
                        ),
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

          // Add bottom padding when the mini-player is showing
          bottomNavigationBar: _playerState != PlayerState.stopped && _currentSong != null
              ? _buildMiniPlayer()
              : null,

        ),

        // Loading overlay with progress
        if (_isLoading)
          Container(
            color: Colors.black.withOpacity(0.5),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    value: _downloadProgress > 0 ? _downloadProgress : null,
                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                    strokeWidth: 5,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    "Downloading... ${(_downloadProgress * 100).toStringAsFixed(1)}%",
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildMiniPlayer() {
    return GestureDetector(
      onTap: () {
        // Open the full player when mini-player is tapped
        if (_currentSong != null) {
          _showMusicPlayer(_currentSong!);
        }
      },
      child: Container(
        height: 70,
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withOpacity(0.3),
              spreadRadius: 1,
              blurRadius: 5,
              offset: const Offset(0, -1),
            ),
          ],
        ),
        child: Row(
          children: [
            // Song thumbnail/icon
            Container(
              width: 50,
              height: 50,
              margin: const EdgeInsets.only(left: 10),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Icon(Icons.music_note, color: Colors.blue),
            ),

            // Song title and progress
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _currentSong?['name'] ?? 'Unknown',
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    // Linear progress indicator
                    StreamBuilder<Duration>(
                      stream: _audioPlayer.onPositionChanged,
                      builder: (context, snapshot) {
                        final position = snapshot.data ?? Duration.zero;
                        final progress = _duration.inMilliseconds > 0
                            ? position.inMilliseconds / _duration.inMilliseconds
                            : 0.0;
                        return LinearProgressIndicator(
                          value: progress.clamp(0.0, 1.0),
                          backgroundColor: Colors.grey[300],
                          valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),

            // Control buttons
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: _playPreviousSong,
                ),
                IconButton(
                  icon: Icon(
                    _playerState == PlayerState.playing
                        ? Icons.pause
                        : Icons.play_arrow,
                  ),
                  onPressed: _pauseResume,
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: _playNextSong,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

}
