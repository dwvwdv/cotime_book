-- The public library moves out of Storage, and gains tags and translated
-- titles.
--
-- Books are now files in a pCloud public folder (AppConstants.libraryUrl):
-- Storage's quota capped the whole library at 1GB, and a maintainer adds a
-- book by dropping it into the folder. The app lists the folder itself, so
-- library_books.path (and rooms.current_book_library_path) now names a file
-- relative to that folder. The cotime-book-library bucket and the
-- library_catalog view stay as they were for apps released before this
-- change; nothing new is put in the bucket.
--
-- Current apps read library_books directly and join it to the folder listing
-- on the device: a file without a row still shows under its file name, and a
-- row without a file shows nothing.

alter table cotime_book.library_books
  -- The title and author as published, when title / author are translated
  -- (a Chinese title for an English book). Searched, not shown.
  add column original_title text,
  add column original_author text,
  -- What the book is found under in the browser's filter; any number of
  -- them. Replaces category for current apps, which ignore that column.
  add column tags text[] not null default '{}'
    constraint library_books_tags_no_nulls
      check (array_position(tags, null) is null);

comment on column cotime_book.library_books.path is
  'The file''s path in the library folder (AppConstants.libraryUrl).';
comment on column cotime_book.library_books.language is
  'BCP 47 tag of the language the book is written in (en, zh-Hant, ja).';
comment on column cotime_book.library_books.category is
  'Read only by apps from before tags; current apps use tags.';

-- The books in the folder when it was set up, all from Project Gutenberg.
-- Titles and tags are in Traditional Chinese; language is the book's own.
-- Only rows that do not exist yet are added, so this never undoes an edit
-- made in the dashboard. Three of these books are larger than the 40MB every
-- device accepts and stay hidden until a smaller copy replaces them.
insert into cotime_book.library_books (
  path, title, original_title, author, original_author, language, tags
)
values
  (
    'pg100-images-3.epub', '莎士比亞全集', 'The Complete Works of William Shakespeare',
    '威廉·莎士比亞', 'William Shakespeare', 'en',
    array['戲劇', '詩歌', '文學經典']
  ),
  (
    'pg103-images-3.epub', '環遊世界八十天', 'Around the World in Eighty Days',
    '儒勒·凡爾納', 'Jules Verne', 'en',
    array['冒險', '文學經典']
  ),
  (
    'pg108-images-3.epub', '福爾摩斯歸來記', 'The Return of Sherlock Holmes',
    '亞瑟·柯南·道爾', 'Arthur Conan Doyle', 'en',
    array['推理', '短篇', '福爾摩斯']
  ),
  (
    'pg1112-images-3.epub', '羅密歐與茱麗葉', 'Romeo and Juliet',
    '威廉·莎士比亞', 'William Shakespeare', 'en',
    array['戲劇', '愛情', '文學經典']
  ),
  (
    'pg11339-images-3.epub', '伊索寓言', 'Aesop''s Fables',
    '伊索', 'Aesop', 'en',
    array['寓言', '兒童', '文學經典']
  ),
  (
    'pg120-images-3.epub', '金銀島', 'Treasure Island',
    '羅伯特·路易斯·史蒂文森', 'Robert Louis Stevenson', 'en',
    array['冒險', '文學經典']
  ),
  (
    'pg1268-images-3.epub', '神祕島', 'The Mysterious Island',
    '儒勒·凡爾納', 'Jules Verne', 'en',
    array['科幻', '冒險']
  ),
  (
    'pg1342-images-3.epub', '傲慢與偏見', 'Pride and Prejudice',
    '珍·奧斯汀', 'Jane Austen', 'en',
    array['愛情', '文學經典']
  ),
  (
    'pg15-images-3.epub', '白鯨記', 'Moby-Dick; or, The Whale',
    '赫爾曼·梅爾維爾', 'Herman Melville', 'en',
    array['冒險', '文學經典']
  ),
  (
    'pg1597-images-3.epub', '安徒生童話', 'Andersen''s Fairy Tales',
    '漢斯·克里斯汀·安徒生', 'Hans Christian Andersen', 'en',
    array['童話', '兒童']
  ),
  (
    'pg16-images-3.epub', '彼得潘', 'Peter Pan',
    '詹姆斯·馬修·巴利', 'J. M. Barrie', 'en',
    array['奇幻', '兒童']
  ),
  (
    'pg164-images-3.epub', '海底兩萬里', 'Twenty Thousand Leagues under the Sea',
    '儒勒·凡爾納', 'Jules Verne', 'en',
    array['科幻', '冒險']
  ),
  (
    'pg1661-images-3.epub', '福爾摩斯冒險史', 'The Adventures of Sherlock Holmes',
    '亞瑟·柯南·道爾', 'Arthur Conan Doyle', 'en',
    array['推理', '短篇', '福爾摩斯']
  ),
  (
    'pg1837-images-3.epub', '王子與貧兒', 'The Prince and the Pauper',
    '馬克·吐溫', 'Mark Twain', 'en',
    array['歷史小說', '文學經典']
  ),
  (
    'pg2130-images-3.epub', '烏托邦', 'Utopia',
    '湯瑪斯·摩爾', 'Thomas More', 'en',
    array['哲學', '文學經典']
  ),
  (
    'pg22298-images-3.epub', '少年實用機械', 'Practical Mechanics for Boys',
    '詹姆斯·斯勞·澤布', 'James Slough Zerbe', 'en',
    array['手作', '科學']
  ),
  (
    'pg2274-images-3.epub', '如何度過每天的二十四小時', 'How to Live on 24 Hours a Day',
    '阿諾德·貝內特', 'Arnold Bennett', 'en',
    array['自我成長']
  ),
  (
    'pg23700-images-3.epub', '十日談', 'The Decameron',
    '喬萬尼·薄伽丘', 'Giovanni Boccaccio', 'en',
    array['短篇', '文學經典']
  ),
  (
    'pg23950-images-3.epub', '三國志演義', 'Romance of the Three Kingdoms',
    '羅貫中', 'Luo Guanzhong', 'zh-Hant',
    array['中國古典', '歷史小說']
  ),
  (
    'pg23962-images-3.epub', '西遊記', 'Journey to the West',
    '吳承恩', 'Wu Cheng''en', 'zh-Hant',
    array['中國古典', '奇幻']
  ),
  (
    'pg2465-images-3.epub', '卡門', 'Carmen',
    '普羅斯佩·梅里美', 'Prosper Mérimée', 'en',
    array['愛情', '文學經典']
  ),
  (
    'pg2488-images-3.epub', '海底兩萬里（Walter 新譯插圖版）', 'Twenty Thousand Leagues Under the Seas: An Underwater Tour of the World',
    '儒勒·凡爾納', 'Jules Verne', 'en',
    array['科幻', '冒險']
  ),
  (
    'pg2527-images-3.epub', '少年維特的煩惱', 'The Sorrows of Young Werther',
    '約翰·沃夫岡·馮·歌德', 'Johann Wolfgang von Goethe', 'en',
    array['愛情', '文學經典']
  ),
  (
    'pg2591-images-3.epub', '格林童話', 'Grimms'' Fairy Tales',
    '格林兄弟', 'Jacob Grimm, Wilhelm Grimm', 'en',
    array['童話', '兒童']
  ),
  (
    'pg25992-images-3.epub', '科學的殉道者：伽利略、第谷與克卜勒', 'The Martyrs of Science',
    '大衛·布魯斯特', 'David Brewster', 'en',
    array['傳記', '科學']
  ),
  (
    'pg2600-images-3.epub', '戰爭與和平', 'War and Peace',
    '列夫·托爾斯泰', 'Leo Tolstoy', 'en',
    array['歷史小說', '文學經典']
  ),
  (
    'pg27200-images-3.epub', '安徒生童話故事集', 'Fairy Tales of Hans Christian Andersen',
    '漢斯·克里斯汀·安徒生', 'Hans Christian Andersen', 'en',
    array['童話', '兒童']
  ),
  (
    'pg28284-images-3.epub', '近代資本主義的演進', 'The Evolution of Modern Capitalism',
    '約翰·阿特金森·霍布森', 'J. A. Hobson', 'en',
    array['經濟', '歷史']
  ),
  (
    'pg28885-images-3.epub', '愛麗絲夢遊仙境（拉克姆插圖版）', 'Alice''s Adventures in Wonderland',
    '路易斯·卡羅', 'Lewis Carroll', 'en',
    array['奇幻', '兒童', '文學經典']
  ),
  (
    'pg30155-images-3.epub', '相對論：狹義與廣義理論', 'Relativity: The Special and General Theory',
    '阿爾伯特·愛因斯坦', 'Albert Einstein', 'en',
    array['科學', '物理']
  ),
  (
    'pg3330-images-3.epub', '論語（理雅各英譯）', 'The Analects of Confucius',
    '孔子', 'Confucius', 'en',
    array['中國古典', '哲學']
  ),
  (
    'pg34823-images-3.epub', '貨幣的價值', 'The Value of Money',
    '班傑明·安德森', 'Benjamin M. Anderson', 'en',
    array['經濟']
  ),
  (
    'pg39713-images-3.epub', '科學的基礎', 'The Foundations of Science',
    '亨利·龐加萊', 'Henri Poincaré', 'en',
    array['科學', '哲學']
  ),
  (
    'pg5000-images-3.epub', '達文西筆記', 'The Notebooks of Leonardo Da Vinci',
    '李奧納多·達文西', 'Leonardo da Vinci', 'en',
    array['藝術', '科學']
  ),
  (
    'pg50954-images-3.epub', '白朗寧詩歌與戲劇全集', 'The Complete Poetic and Dramatic Works of Robert Browning',
    '羅伯特·白朗寧', 'Robert Browning', 'en',
    array['詩歌', '戲劇']
  ),
  (
    'pg51775-images-3.epub', '一千零一夜（第二卷）', 'The Book of the Thousand Nights and a Night, Volume 2',
    '理查·伯頓（英譯）', 'Richard Francis Burton', 'en',
    array['民間故事', '奇幻']
  ),
  (
    'pg55-images-3.epub', '綠野仙蹤', 'The Wonderful Wizard of Oz',
    '李曼·法蘭克·鮑姆', 'L. Frank Baum', 'en',
    array['奇幻', '兒童']
  ),
  (
    'pg56006-images-3.epub', '一千種賺錢方法', 'One Thousand Ways to Make Money',
    '佩吉·福克斯', 'Page Fox', 'en',
    array['商業']
  ),
  (
    'pg60979-images-3.epub', '股票作手回憶錄', 'Reminiscences of a Stock Operator',
    '艾德溫·勒菲弗', 'Edwin Lefèvre', 'en',
    array['投資', '商業']
  ),
  (
    'pg65238-images-3.epub', '煙囪的秘密', 'The Secret of Chimneys',
    '阿嘉莎·克莉絲蒂', 'Agatha Christie', 'en',
    array['推理']
  ),
  (
    'pg66944-images-3.epub', '相對性原理', 'The Principle of Relativity',
    '阿爾伯特·愛因斯坦、赫爾曼·閔考斯基', 'Albert Einstein, Hermann Minkowski', 'en',
    array['科學', '物理']
  ),
  (
    'pg67138-images-3.epub', '太陽依舊升起', 'The Sun Also Rises',
    '厄尼斯特·海明威', 'Ernest Hemingway', 'en',
    array['文學經典']
  ),
  (
    'pg7213-images-3.epub', '我的生活與工作', 'My Life and Work',
    '亨利·福特', 'Henry Ford', 'en',
    array['傳記', '商業']
  ),
  (
    'pg75948-images-3.epub', '奇妙之書', 'The Book of Wonders',
    null, null, 'en',
    array['科學', '百科']
  ),
  (
    'pg768-images-3.epub', '咆哮山莊', 'Wuthering Heights',
    '艾蜜莉·勃朗特', 'Emily Brontë', 'en',
    array['愛情', '文學經典']
  ),
  (
    'pg829-images-3.epub', '格列佛遊記', 'Gulliver''s Travels',
    '強納森·史威夫特', 'Jonathan Swift', 'en',
    array['諷刺', '奇幻', '文學經典']
  ),
  (
    'pg834-images-3.epub', '福爾摩斯回憶錄', 'The Memoirs of Sherlock Holmes',
    '亞瑟·柯南·道爾', 'Arthur Conan Doyle', 'en',
    array['推理', '短篇', '福爾摩斯']
  ),
  (
    'pg996-images-3.epub', '唐吉訶德', 'Don Quixote',
    '米格爾·德·塞萬提斯', 'Miguel de Cervantes Saavedra', 'en',
    array['諷刺', '文學經典']
  )
on conflict (path) do nothing;
