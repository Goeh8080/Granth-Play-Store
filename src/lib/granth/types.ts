export type Topic = {
  id: string;
  title: string;
  description: string;
  position: string;
  user: string;
  created_at: string;
  granth_count: string;
  praman_count: string;
};

export type Granth = {
  id: string;
  title: string;
  author: string;
  topic_id: string | null;
  description: string;
  imagePath: string;
  editorImagePath: string;
  granthURL?: string;
  position: string;
  user: string;
  created_at: string;
  pramanCount: string;
};

export type Praman = {
  id: string;
  title: string;
  description: string;
  is_favorate: string;
  topic_id: string;
  granth_id: string;
  image_path: string;
  youtube_url: string;
  youtube_start: string;
  youtube_desc: string;
  user: string;
  created_at: string;
  topic_title: string;
  granth_title: string;
  granth_image: string;
  editorImagePath: string;
  granth_auther: string;
};

export type Panel = "dashboard" | "topics" | "granths" | "pramans" | "gallery";

export type AppRoute = {
  panel: Panel;
  topicId?: string;
  granthId?: string;
  pramanId?: string;
};

export type GalleryFolder = {
  id: string;
  name: string;
};

export type GalleryItem = {
  id: string;
  kind: "image" | "pdf";
  title: string;
  text: string;
  topic: string;
  granth: string;
  folderId: string;
  createdAt: number;
  size: number;
  fileName: string;
  blob: Blob;
  preview?: Blob;
};
export type Catalog = {
  topics: Topic[];
  granths: Granth[];
  pramans: Praman[];
  syncedAt: number;
};

export type ApiEnvelope<T> = {
  success?: boolean;
  data?: T[];
};
