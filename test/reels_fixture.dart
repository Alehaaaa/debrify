class FakeTmdb {
  FakeTmdb({
    this.noClip = const <int>{},
    this.description,
    this.rating = 7.8,
    this.pages = 2,
  });

  final Set<int> noClip;
  final String? description;
  final double? rating;
  final int pages;
  final List<String> requests = <String>[];

  int get detailRequests => requests
      .where((request) => RegExp(r'^(movie|tv)/\d+$').hasMatch(request))
      .length;
  int get listRequests =>
      requests.where((request) => request.endsWith('/popular')).length;

  Future<Map<String, dynamic>> get(
    String path,
    Map<String, String> query,
  ) async {
    requests.add(path);
    final list = RegExp(r'^(movie|tv)/popular$').firstMatch(path);
    if (list != null) {
      final type = list.group(1)!;
      final page = int.parse(query['page']!);
      final base = type == 'movie' ? 1000 : 2000;
      return <String, dynamic>{
        'total_pages': pages,
        'results': page > pages
            ? <dynamic>[]
            : <dynamic>[
                for (var index = 0; index < 2; index++)
                  <String, dynamic>{
                    'id': base + page * 10 + index,
                    'title': 'x',
                  },
              ],
      };
    }
    final id = int.parse(path.split('/').last);
    final movie = path.startsWith('movie/');
    return <String, dynamic>{
      movie ? 'title' : 'name': 'Title $id',
      movie ? 'release_date' : 'first_air_date': '2001-02-03',
      'overview': description ?? 'About $id.',
      if (rating != null) 'vote_average': rating,
      'genres': <dynamic>[
        <String, dynamic>{'id': 1, 'name': 'Comedy'},
        <String, dynamic>{'id': 2, 'name': 'Romance'},
      ],
      'external_ids': <String, dynamic>{'imdb_id': 'tt$id'},
      'videos': <String, dynamic>{
        'results': <dynamic>[
          <String, dynamic>{
            'site': 'YouTube',
            'type': 'Trailer',
            'key': 'trailer0000',
          },
          if (!noClip.contains(id))
            <String, dynamic>{
              'site': 'YouTube',
              'type': 'Clip',
              'key': 'clip${id.toString().padLeft(7, '0')}',
              'name': "'Scene $id'",
              'official': true,
            },
        ],
      },
    };
  }
}
