/** 视频软件解码渲染模块 */
export const create: (surfaceId: string, fd: number, offset: number, length: number, preferSoftware: boolean) => number;
export const setClock: (id: number, ms: number) => void;
export const setPaused: (id: number, paused: boolean) => void;
export const seek: (id: number, ms: number) => void;
export const release: (id: number) => void;
export const info: (id: number) => string;
